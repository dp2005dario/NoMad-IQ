module github.com/dp2005dario/NoMad-IQ/services/notifier

go 1.24.0

// El código generado desde proto/ vive en este mismo repositorio.
replace github.com/dp2005dario/NoMad-IQ/gen/go => ../../gen/go

require (
	github.com/cloudflare/circl v1.6.4
	github.com/dp2005dario/NoMad-IQ/gen/go v0.0.0-00010101000000-000000000000
	github.com/google/uuid v1.6.0
	github.com/jackc/pgx/v5 v5.7.2
	github.com/redis/go-redis/v9 v9.22.0
	github.com/twmb/franz-go v1.18.1
	golang.org/x/oauth2 v0.35.0
	golang.org/x/sync v0.18.0
	golang.org/x/time v0.14.0
	google.golang.org/protobuf v1.36.5
)

require (
	cloud.google.com/go/compute/metadata v0.5.0 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/klauspost/compress v1.17.11 // indirect
	github.com/pierrec/lz4/v4 v4.1.22 // indirect
	github.com/twmb/franz-go/pkg/kmsg v1.9.0 // indirect
	go.uber.org/atomic v1.11.0 // indirect
	golang.org/x/crypto v0.45.0 // indirect
	golang.org/x/net v0.47.0 // indirect
	golang.org/x/sys v0.38.0 // indirect
	golang.org/x/text v0.31.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20240903143218-8af14fe29dc1 // indirect
	google.golang.org/grpc v1.68.0 // indirect
)
