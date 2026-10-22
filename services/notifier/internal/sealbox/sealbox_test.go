package sealbox

import (
	"bytes"
	"encoding/hex"
	"errors"
	"testing"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Vector oficial del RFC 9180 (modo base, X25519 + HKDF-SHA256 + AES-256-GCM,
// primer mensaje). Si nuestro cableado de la librería no diera EXACTAMENTE
// estos bytes, la app (que usará otra implementación de HPKE) no podría leerlos.
func TestSealMatchesRFC9180Vector(t *testing.T) {
	info := mustHex(t, "4f6465206f6e2061204772656369616e2055726e")
	ikmE := mustHex(t, "2cd7c601cefb3d42a62b04b7a9041494c06c7843818e0ce28a8f704ae7ab20f9")
	pkR := mustHex(t, "430f4b9859665145a6b1ba274024487bd66f03a2dd577d7753c68d7d7d00c00c")
	skR := mustHex(t, "497b4502664cfea5d5af0b39934dac72242a74f8480451e1aee7d6a53320333d")
	pt := mustHex(t, "4265617574792069732074727574682c20747275746820626561757479")
	aad := mustHex(t, "436f756e742d30")
	want := append(mustHex(t, "6c93e09869df3402d7bf231bf540fadd35cd56be14f97178f0954db94b7fc256"),
		mustHex(t, "e5d84cd531cfb583096e7cfa9641bd3079cf3a91cda813c52deb5f512be9931980a41de125a925cdad859d5b7a")...)

	got, err := seal(bytes.NewReader(ikmE), info, pkR, pt, aad)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("cifrado distinto del RFC:\n got %x\nwant %x", got, want)
	}
	back, err := open(info, skR, got, aad)
	if err != nil || !bytes.Equal(back, pt) {
		t.Fatalf("no se recupera el texto: %v", err)
	}
}

func TestOnlyTheRightDeviceCanOpen(t *testing.T) {
	pub, priv, err := GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	_, otherPriv, err := GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte(`{"zone_id":"x"}`)
	box, err := SealForDevice(pub, msg, []byte("device-1"))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := OpenOnDevice(priv, box, []byte("device-1")); err != nil || !bytes.Equal(got, msg) {
		t.Fatalf("el teléfono correcto debe poder leerlo: %v", err)
	}
	if _, err := OpenOnDevice(otherPriv, box, []byte("device-1")); !errors.Is(err, ErrOpen) {
		t.Fatal("otro teléfono no debe poder leerlo")
	}
	if _, err := OpenOnDevice(priv, box, []byte("device-2")); !errors.Is(err, ErrOpen) {
		t.Fatal("copiado a otro device_id no debe poder leerse")
	}
	box[len(box)-1] ^= 1
	if _, err := OpenOnDevice(priv, box, []byte("device-1")); !errors.Is(err, ErrOpen) {
		t.Fatal("un mensaje manipulado debe rechazarse")
	}
	again, err := SealForDevice(pub, msg, []byte("device-1"))
	if err != nil || bytes.Equal(again[:32], box[:32]) {
		t.Fatal("cada mensaje debe usar una clave efímera nueva")
	}
}

func TestWeakPublicKeysAreRejected(t *testing.T) {
	for name, key := range map[string][]byte{
		"corta":        make([]byte, 31),
		"todo ceros":   make([]byte, 32),
		"orden bajo 1": append([]byte{1}, make([]byte, 31)...),
	} {
		if err := CheckPublicKey(key); !errors.Is(err, ErrInvalidPublicKey) {
			t.Errorf("%s: se esperaba ErrInvalidPublicKey, llegó %v", name, err)
		}
	}
}

func TestVaultTokensAndBlindIndex(t *testing.T) {
	v, err := NewVault(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := v.EncryptToken("dev-1", "token-abc")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, []byte("token-abc")) {
		t.Fatal("el token no puede quedar en claro")
	}
	if got, err := v.DecryptToken("dev-1", sealed); err != nil || got != "token-abc" {
		t.Fatalf("DecryptToken = %q, %v", got, err)
	}
	if _, err := v.DecryptToken("dev-2", sealed); !errors.Is(err, ErrOpen) {
		t.Fatal("el token cifrado está atado a su device_id")
	}
	if !bytes.Equal(v.TokenIndex("t"), v.TokenIndex("t")) || bytes.Equal(v.TokenIndex("t"), v.TokenIndex("u")) {
		t.Fatal("el índice ciego debe ser estable y distinto por token")
	}
	other, err := NewVault(bytes.Repeat([]byte{8}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(v.SpamKey("a", "b"), other.SpamKey("a", "b")) || bytes.Equal(v.SpamKey("ab"), v.SpamKey("a", "b")) {
		t.Fatal("las claves anti-spam dependen de la clave y separan las partes")
	}
	if _, err := NewVault(make([]byte, 8)); err == nil {
		t.Fatal("una clave maestra corta debe rechazarse")
	}
}
