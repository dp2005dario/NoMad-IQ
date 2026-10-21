package store

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Los ficheros SQL se "incrustan" dentro del binario al compilar (embed).
// Así la imagen Docker no necesita copiar la carpeta migrations aparte y es
// imposible desplegar un binario con migraciones que no le corresponden.
//
//go:embed migrations/*.sql
var migrationFiles embed.FS

// migrationLockID es un número arbitrario pero fijo. Sirve de "llave" para
// que, si arrancan 3 copias del servicio a la vez, solo una migre y las demás
// esperen (pg_advisory_lock). Sin esto, dos copias podrían crear la misma
// tabla a la vez y una fallaría.
const migrationLockID int64 = 0x7072696365 // "price" en hexadecimal

type migration struct {
	version  int
	name     string
	sql      string
	checksum string
}

func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return nil, fmt.Errorf("leer migraciones: %w", err)
	}
	var out []migration
	seen := map[int]string{}
	for _, e := range entries {
		// Formato obligatorio: 0001_descripcion.sql
		prefix, _, ok := strings.Cut(e.Name(), "_")
		version, err := strconv.Atoi(prefix)
		if !ok || err != nil || version <= 0 {
			return nil, fmt.Errorf("migración con nombre inválido %q (usa 0001_descripcion.sql)", e.Name())
		}
		if other, dup := seen[version]; dup {
			return nil, fmt.Errorf("versión %d repetida: %s y %s", version, other, e.Name())
		}
		seen[version] = e.Name()
		body, err := migrationFiles.ReadFile("migrations/" + e.Name())
		if err != nil {
			return nil, fmt.Errorf("leer %s: %w", e.Name(), err)
		}
		sum := sha256.Sum256(body)
		out = append(out, migration{version: version, name: e.Name(), sql: string(body), checksum: hex.EncodeToString(sum[:])})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].version < out[j].version })
	return out, nil
}

// Migrate aplica las migraciones pendientes, en orden, cada una en su propia
// transacción. Devuelve cuántas aplicó.
//
// Además guarda la huella (SHA-256) de cada fichero: si alguien edita una
// migración YA aplicada, el servicio se niega a arrancar en lugar de dejar
// bases de datos distintas en cada entorno sin que nadie se entere.
func (p *Postgres) Migrate(ctx context.Context) (int, error) {
	migrations, err := loadMigrations()
	if err != nil {
		return 0, err
	}

	// El bloqueo pertenece a una conexión concreta: hay que reservar una.
	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("migrar: obtener conexión: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrationLockID); err != nil {
		return 0, fmt.Errorf("migrar: obtener bloqueo: %w", err)
	}
	defer func() {
		// Se libera con un contexto propio: aunque ctx se haya cancelado,
		// el bloqueo no debe quedarse tomado.
		_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, migrationLockID)
	}()

	if _, err := conn.Exec(ctx, `
		CREATE SCHEMA IF NOT EXISTS flights;
		CREATE TABLE IF NOT EXISTS flights.price_consumer_migrations (
			version    integer     PRIMARY KEY,
			name       text        NOT NULL,
			checksum   text        NOT NULL,
			applied_at timestamptz NOT NULL DEFAULT now()
		)`); err != nil {
		return 0, fmt.Errorf("migrar: crear tabla de control: %w", err)
	}

	rows, err := conn.Query(ctx, `SELECT version, checksum FROM flights.price_consumer_migrations`)
	if err != nil {
		return 0, fmt.Errorf("migrar: leer versiones aplicadas: %w", err)
	}
	applied := map[int]string{}
	for rows.Next() {
		var (
			v   int
			sum string
		)
		if err := rows.Scan(&v, &sum); err != nil {
			rows.Close()
			return 0, fmt.Errorf("migrar: leer versiones aplicadas: %w", err)
		}
		applied[v] = sum
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("migrar: leer versiones aplicadas: %w", err)
	}

	count := 0
	var errs []error
	for _, m := range migrations {
		if sum, ok := applied[m.version]; ok {
			if sum != m.checksum {
				errs = append(errs, fmt.Errorf("la migración %s ya aplicada ha sido modificada: crea una nueva en lugar de editarla", m.name))
			}
			continue
		}
		if len(errs) > 0 {
			break
		}
		err := pgx.BeginTxFunc(ctx, conn, pgx.TxOptions{}, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, m.sql); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO flights.price_consumer_migrations (version, name, checksum) VALUES ($1, $2, $3)`,
				m.version, m.name, m.checksum)
			return err
		})
		if err != nil {
			return count, fmt.Errorf("migrar: aplicar %s: %w", m.name, err)
		}
		count++
	}
	return count, errors.Join(errs...)
}
