module github.com/dp2005dario/NoMad-IQ/services/flight-ingestor

go 1.24.0

// El código generado desde proto/ vive en este mismo repositorio.
replace github.com/dp2005dario/NoMad-IQ/gen/go => ../../gen/go

require (
	github.com/dp2005dario/NoMad-IQ/gen/go v0.0.0
	github.com/google/uuid v1.6.0
	github.com/twmb/franz-go v1.18.1
	golang.org/x/sync v0.10.0
	golang.org/x/time v0.14.0
	google.golang.org/grpc v1.68.0
	google.golang.org/protobuf v1.36.5
)

require (
	github.com/klauspost/compress v1.17.11 // indirect
	github.com/pierrec/lz4/v4 v4.1.22 // indirect
	github.com/twmb/franz-go/pkg/kmsg v1.9.0 // indirect
	golang.org/x/net v0.29.0 // indirect
	golang.org/x/sys v0.25.0 // indirect
	golang.org/x/text v0.18.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20240903143218-8af14fe29dc1 // indirect
)
