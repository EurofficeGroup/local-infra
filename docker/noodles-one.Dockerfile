ARG NOODLES_IMAGE

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

WORKDIR /src
COPY NuGet.Config ./
COPY src/ src/
COPY ["NServiceBus License/", "NServiceBus License/"]

ARG BUILD_CONFIG=Release
ARG SERVICE

RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish "src/$SERVICE/$SERVICE.csproj" \
        -c "$BUILD_CONFIG" \
        -p:Optimize=false \
        -o "/app/$SERVICE" \
        --no-self-contained

FROM ${NOODLES_IMAGE}
ARG SERVICE
COPY --from=build /app/$SERVICE /app/$SERVICE
