// Comando notifyctl: herramienta para probar a mano los avisos cifrados.
//
// Hace lo que hará la app en el teléfono, para que puedas comprobarlo desde
// la terminal (y para que lo use la CI):
//
//	notifyctl keygen
//	    Crea un par de claves de teléfono. Imprime JSON con public_key
//	    (la que se registra en el notifier) y private_key (la que se queda
//	    el teléfono y NUNCA sale de él).
//
//	notifyctl open -key <private_key> -device <device_id> -payload <campo p>
//	    Descifra el campo "p" de un aviso recibido (por ejemplo, de
//	    GET /messages del FCM falso) e imprime el JSON del aviso.
package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "keygen":
		pub, priv, err := sealbox.GenerateDeviceKeys()
		if err != nil {
			fail(err)
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{
			"public_key":  base64.RawURLEncoding.EncodeToString(pub),
			"private_key": base64.RawURLEncoding.EncodeToString(priv),
		})
	case "open":
		fs := flag.NewFlagSet("open", flag.ExitOnError)
		key := fs.String("key", "", "clave privada del teléfono (base64url)")
		device := fs.String("device", "", "device_id con el que se registró el teléfono")
		payload := fs.String("payload", "", `campo "p" del aviso (base64url)`)
		_ = fs.Parse(os.Args[2:])
		priv, err := base64.RawURLEncoding.DecodeString(*key)
		if err != nil {
			fail(fmt.Errorf("-key no es base64url"))
		}
		envelope, err := base64.RawURLEncoding.DecodeString(*payload)
		if err != nil {
			fail(fmt.Errorf("-payload no es base64url"))
		}
		plain, err := sealbox.OpenOnDevice(priv, envelope, []byte(*device))
		if err != nil {
			fail(err)
		}
		fmt.Println(string(plain))
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "uso: notifyctl keygen | notifyctl open -key K -device ID -payload P")
	os.Exit(2)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "notifyctl:", err)
	os.Exit(1)
}
