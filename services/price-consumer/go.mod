module github.com/dp2005dario/NoMad-IQ/services/price-consumer

go 1.24

// El código generado desde proto/ vive en este mismo repositorio.
replace github.com/dp2005dario/NoMad-IQ/gen/go => ../../gen/go

require (
	github.com/dp2005dario/NoMad-IQ/gen/go v0.0.0
	github.com/google/uuid v1.6.0
	github.com/jackc/pgx/v5 v5.7.2
	github.com/twmb/franz-go v1.18.1
	golang.org/x/sync v0.10.0
	google.golang.org/grpc v1.68.0
	google.golang.org/protobuf v1.36.5
)

require (
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/klauspost/compress v1.17.11 // indirect
	github.com/pierrec/lz4/v4 v4.1.22 // indirect
	github.com/twmb/franz-go/pkg/kmsg v1.9.0 // indirect
	golang.org/x/crypto v0.32.0 // indirect
	golang.org/x/net v0.29.0 // indirect
	golang.org/x/sys v0.29.0 // indirect
	golang.org/x/text v0.21.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20240903143218-8af14fe29dc1 // indirect
)
