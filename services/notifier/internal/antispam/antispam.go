// Package antispam evita que un paseo por el centro se convierta en una
// lluvia de avisos.
//
// Dos reglas, guardadas en Redis con caducidad automática (TTL):
//
//  1. ENFRIAMIENTO por persona: después de un aviso, silencio durante
//     NOTIFY_COOLDOWN (45 min). Cruzar de la Plaza Mayor a Sol y de ahí al
//     Palacio Real en 15 minutos da UN aviso, no tres. Los avisos urgentes
//     (seguridad) se saltan esta regla.
//  2. NO REPETIR ZONA: la misma zona no se anuncia dos veces a la misma
//     persona en NOTIFY_ZONE_REPEAT_WINDOW (24 h), aunque salga y vuelva.
//
// Las dos comprobaciones y las dos escrituras van en UN script Lua, que
// Redis ejecuta de forma atómica (nadie puede colarse entre medias). Si se
// hicieran por separado, dos entradas casi simultáneas podrían ver "no hay
// enfriamiento" a la vez y enviar dos avisos.
//
// Privacidad: los nombres de las claves no contienen el seudónimo ni la
// zona, sino un HMAC con una clave del notifier (ver sealbox.Vault.SpamKey).
// Quien vea el contenido de Redis solo ve números aleatorios con caducidad.
//
// Redis Cluster: las dos claves de una persona llevan la misma "etiqueta"
// entre llaves {…}, así caen en el mismo nodo y el script puede usarlas juntas.
package antispam

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// Verdict es la respuesta del control anti-spam.
type Verdict int

// Respuestas posibles.
const (
	// Send: adelante, ya quedó apuntado.
	Send Verdict = iota + 1
	// Repeat: esa zona ya se anunció a esta persona hace poco.
	Repeat
	// Cooldown: esta persona recibió otro aviso hace poco.
	Cooldown
)

func (v Verdict) String() string {
	switch v {
	case Send:
		return "send"
	case Repeat:
		return "repeat"
	case Cooldown:
		return "cooldown"
	default:
		return "unknown"
	}
}

// KeyNamer da nombres opacos (HMAC) para las claves.
type KeyNamer interface {
	SpamKey(parts ...string) []byte
}

// admitScript: KEYS[1] = zona, KEYS[2] = enfriamiento.
// ARGV[1] = TTL de la zona (ms), ARGV[2] = TTL del enfriamiento (ms, 0 =
// sin enfriamiento), ARGV[3] = "1" si es urgente.
var admitScript = redis.NewScript(`
if redis.call('EXISTS', KEYS[1]) == 1 then
  return 'repeat'
end
local cooldown = tonumber(ARGV[2])
if ARGV[3] ~= '1' and cooldown > 0 and redis.call('EXISTS', KEYS[2]) == 1 then
  return 'cooldown'
end
redis.call('SET', KEYS[1], '1', 'PX', ARGV[1])
if cooldown > 0 then
  redis.call('SET', KEYS[2], '1', 'PX', cooldown)
end
return 'send'
`)

// Gate aplica las dos reglas.
type Gate struct {
	rdb        redis.Scripter
	del        func(ctx context.Context, keys ...string) error
	names      KeyNamer
	zoneWindow time.Duration
	cooldown   time.Duration
}

// Client es lo que necesita Gate de Redis (un *redis.Client lo cumple).
type Client interface {
	redis.Scripter
	Del(ctx context.Context, keys ...string) *redis.IntCmd
}

// New crea el control anti-spam.
func New(rdb Client, names KeyNamer, zoneWindow, cooldown time.Duration) (*Gate, error) {
	if zoneWindow <= 0 || cooldown < 0 {
		return nil, errors.New("antispam: ventanas inválidas")
	}
	return &Gate{
		rdb:        rdb,
		del:        func(ctx context.Context, keys ...string) error { return rdb.Del(ctx, keys...).Err() },
		names:      names,
		zoneWindow: zoneWindow,
		cooldown:   cooldown,
	}, nil
}

func (g *Gate) keys(recipient, zoneID string) (zone, cooldown string) {
	tag := hex.EncodeToString(g.names.SpamKey("person", recipient))
	zone = "notify:{" + tag + "}:z:" + hex.EncodeToString(g.names.SpamKey("zone", recipient, zoneID))
	cooldown = "notify:{" + tag + "}:c"
	return zone, cooldown
}

// Admit decide si se avisa y, si es que sí, lo deja apuntado en el mismo paso.
func (g *Gate) Admit(ctx context.Context, recipient, zoneID string, urgent bool) (Verdict, error) {
	zone, cooldown := g.keys(recipient, zoneID)
	urgentArg := "0"
	if urgent {
		urgentArg = "1"
	}
	res, err := admitScript.Run(ctx, g.rdb, []string{zone, cooldown},
		g.zoneWindow.Milliseconds(), g.cooldown.Milliseconds(), urgentArg).Text()
	if err != nil {
		return 0, fmt.Errorf("antispam: redis: %w", err)
	}
	switch res {
	case "send":
		return Send, nil
	case "repeat":
		return Repeat, nil
	case "cooldown":
		return Cooldown, nil
	default:
		return 0, fmt.Errorf("antispam: respuesta inesperada %q", res)
	}
}

// Release deshace un Admit cuyo aviso no se pudo encolar (por ejemplo,
// PostgreSQL caído): así, al reintentar el mensaje, no se toma por repetido.
// En el peor caso (si había un enfriamiento previo y era urgente) se pierde
// ese enfriamiento: un aviso de más, nunca uno de menos.
func (g *Gate) Release(ctx context.Context, recipient, zoneID string) error {
	zone, cooldown := g.keys(recipient, zoneID)
	if err := g.del(ctx, zone, cooldown); err != nil {
		return fmt.Errorf("antispam: redis: %w", err)
	}
	return nil
}
