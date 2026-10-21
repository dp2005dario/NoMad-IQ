# syntax=docker/dockerfile:1
# Construcción en dos etapas, como los servicios Go:
#   1) "build": una imagen grande con JDK y Maven que compila el .jar;
#   2) final: solo el JRE (para ejecutar, no compilar) en una imagen
#      "distroless": sin shell, sin gestor de paquetes, ejecutándose sin root.
#      Si un atacante lograra ejecutar algo dentro, no tendría herramientas.
#
# Se construye desde la raíz del repositorio (igual que los demás servicios):
#   docker build -f services/auth-gateway/Dockerfile .

FROM eclipse-temurin:21-jdk AS build
WORKDIR /src

# Primero solo el pom.xml y el wrapper: Docker cachea la descarga de
# dependencias y no la repite mientras el pom.xml no cambie.
COPY services/auth-gateway/mvnw services/auth-gateway/pom.xml ./
COPY services/auth-gateway/.mvn ./.mvn
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q dependency:go-offline

COPY services/auth-gateway/src ./src
# Los tests ya los pasa la CI; aquí solo empaquetamos. Después, "extract"
# separa nuestras clases de las librerías: arranque más rápido y permite
# lanzar HealthProbe con un classpath normal.
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q package -DskipTests \
 && java -Djarmode=tools -jar target/auth-gateway.jar extract --destination /out

FROM gcr.io/distroless/java21-debian12:nonroot
WORKDIR /app
COPY --from=build /out/ /app/
USER nonroot:nonroot
EXPOSE 8083 8084
# Java dentro de contenedores: usa como mucho el 75 % de la memoria asignada.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=3 \
  CMD ["java", "-cp", "/app/auth-gateway.jar", "com.nomadiq.authgateway.HealthProbe"]
ENTRYPOINT ["java", "-jar", "/app/auth-gateway.jar"]
