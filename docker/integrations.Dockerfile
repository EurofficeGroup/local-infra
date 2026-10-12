# Noodles services that live in the eurofficegroup.integrations repo, not in
# noodles. Today that is only Noodles.SearchEs, the Elasticsearch indexer used
# by the 'search' profile (docker-compose.noodles.yml, service noodles-searches).
#
# Build context is C:\workspace\integrations. The repo has the same shape as
# noodles (NuGet.Config at the root, src/, "NServiceBus License/", plus
# SharedConfig/ that the csproj links log4net.config from), so this is
# noodles.Dockerfile with a different service list.
#
# SERVICES is a space-separated list of project names under src/. Each is
# published into /app/<name>, and NOODLES_SERVICE picks which one runs - the
# same contract as infra/noodles:local, so compose services look alike.

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

# The internal feed is plain HTTP and needs the VPN, exactly as for noodles.
WORKDIR /src
COPY NuGet.Config ./

COPY src/ src/
COPY SharedConfig/ SharedConfig/
# JSON form: the path contains a space, and the shell form cannot express that.
COPY ["NServiceBus License/", "NServiceBus License/"]

ARG BUILD_CONFIG=Release
ARG SERVICES="Noodles.SearchEs"

RUN set -eux; \
    for p in $SERVICES; do \
        dotnet publish "src/$p/$p.csproj" \
            -c "$BUILD_CONFIG" \
            -o "/app/$p" \
            --no-self-contained; \
    done

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/runtime:8.0 AS final

WORKDIR /app
COPY --from=build /app /app

ENV NOODLES_SERVICE=Noodles.SearchEs
ENV DOTNET_ENVIRONMENT=Development

# exec so the app is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["/bin/sh", "-c", "exec dotnet \"/app/$NOODLES_SERVICE/$NOODLES_SERVICE.dll\""]
