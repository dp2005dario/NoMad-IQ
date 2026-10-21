// Test de seguridad mTLS. Crea en memoria una autoridad certificadora (CA)
// falsa, emite certificados con ella y comprueba quién puede conectarse.

package grpcserver

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"log/slog"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"

	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/watchlist"
)

// Este test demuestra el zero trust: con mTLS, un cliente sin certificado de
// nuestra CA no puede ni siquiera hacer una llamada.

// pki (infraestructura de clave pública) agrupa el certificado y la clave
// privada de una CA de pruebas, capaz de "firmar carnés" para servicios.
type pki struct {
	caCert *x509.Certificate
	caKey  *ecdsa.PrivateKey
	caPEM  []byte
}

// newPKI crea una CA nueva con una clave ECDSA P-256 (criptografía de curva
// elíptica: claves pequeñas y muy seguras). Solo vale una hora.
func newPKI(t *testing.T) *pki {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "nomadiq-test-ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	return &pki{caCert: cert, caKey: key, caPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})}
}

// issue emite un certificado firmado por la CA. usage indica si es para un
// servidor (ServerAuth) o para un cliente (ClientAuth).
func (p *pki) issue(t *testing.T, cn string, usage x509.ExtKeyUsage) (certPEM, keyPEM []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{usage},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, p.caCert, &key.PublicKey, p.caKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
}

// writeFile guarda datos en un fichero temporal con permisos 0600 (solo el
// dueño puede leerlo), como se haría con una clave privada real.
func writeFile(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestMTLSRejectsClientsWithoutCertificate(t *testing.T) {
	ca := newPKI(t)
	dir := t.TempDir()
	srvCert, srvKey := ca.issue(t, "flight-ingestor", x509.ExtKeyUsageServerAuth)
	tlsCfg, err := ServerTLSConfig(TLSFiles{
		CertFile:     writeFile(t, dir, "server.pem", srvCert),
		KeyFile:      writeFile(t, dir, "server-key.pem", srvKey),
		ClientCAFile: writeFile(t, dir, "ca.pem", ca.caPEM),
	})
	if err != nil {
		t.Fatal(err)
	}
	store, _ := watchlist.New(10)
	srv, _ := NewServer(NewService(store), tlsCfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(ca.caPEM)

	call := func(clientCfg *tls.Config) error {
		conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(credentials.NewTLS(clientCfg)))
		if err != nil {
			return err
		}
		defer conn.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_, err = flightsv1.NewRouteWatchServiceClient(conn).ListRouteWatches(ctx, &flightsv1.ListRouteWatchesRequest{})
		return err
	}

	// 1) Cliente que confía en el servidor pero no presenta certificado: rechazado.
	if err := call(&tls.Config{RootCAs: roots, ServerName: "localhost", MinVersion: tls.VersionTLS13}); err == nil {
		t.Fatal("un cliente sin certificado no debería poder llamar")
	}

	// 2) Cliente con certificado firmado por nuestra CA: aceptado.
	cliCertPEM, cliKeyPEM := ca.issue(t, "auth-gateway", x509.ExtKeyUsageClientAuth)
	cliCert, err := tls.X509KeyPair(cliCertPEM, cliKeyPEM)
	if err != nil {
		t.Fatal(err)
	}
	ok := &tls.Config{RootCAs: roots, ServerName: "localhost", Certificates: []tls.Certificate{cliCert}, MinVersion: tls.VersionTLS13}
	if err := call(ok); err != nil {
		t.Fatalf("un cliente con certificado válido debería poder llamar: %v", err)
	}

	// 3) Cliente con certificado de OTRA CA: rechazado.
	other := newPKI(t)
	badCertPEM, badKeyPEM := other.issue(t, "intruso", x509.ExtKeyUsageClientAuth)
	badCert, _ := tls.X509KeyPair(badCertPEM, badKeyPEM)
	bad := &tls.Config{RootCAs: roots, ServerName: "localhost", Certificates: []tls.Certificate{badCert}, MinVersion: tls.VersionTLS13}
	if err := call(bad); err == nil {
		t.Fatal("un certificado de otra CA no debería ser aceptado")
	}
}
