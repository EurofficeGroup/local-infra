# Configuration API.
#
# Build context is C:\workspace\api.configuration.
#
# The Dockerfile in that repo is stale - it targets microsoft/dotnet-framework:4.7.1
# and copies a bin\Debug that no longer matches the project, which is now net8.0.
# This one builds from source.
#
# Everything else depends on this service: each Noodles endpoint calls it at
# startup (HostBuilderExtensions.BootstrapConfiguration) and reads its database
# connection strings, transport and cache settings from it.

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

WORKDIR /src
# This repo keeps its NuGet.Config in .nuget/, not at the root (unlike noodles,
# which has one in both places). NuGet's own discovery walks parent directories
# looking for nuget.config and does not look inside .nuget/, so copy it to where
# restore will actually find it.
COPY .nuget/NuGet.Config ./NuGet.Config
COPY src/ src/

ARG BUILD_CONFIG=Release

RUN dotnet publish \
        "src/EurofficeGroup.Api.Configuration.Service/EurofficeGroup.Api.Configuration.Service.csproj" \
        -c "$BUILD_CONFIG" \
        -o /app \
        --no-self-contained

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final

# curl is only here for the container healthcheck below. The aspnet image ships
# neither curl nor wget, and its /bin/sh is dash, which has no /dev/tcp.
RUN apt-get update  && apt-get install -y --no-install-recommends curl  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app /app

# Read by ConfigureEoWebHostUsingStartup(..., "ConfigurationApiPort").
# 8080 is what every Noodles appsettings.json expects.
ENV ConfigurationApiPort=8080
EXPOSE 8080

# Compose supplies Generic, DealerGroup and Environment. Generic carries the
# <env>_<group> prefix and is therefore the group switch - see
# config-samples/api.configuration.appsettings.local.json.

# Healthy only when it can actually serve configuration, which means the database
# is reachable and the group's support centre is restored. The Noodles services
# wait for this, so a database that is not ready yet holds them back instead of
# sending sixteen containers into a crash loop.
#
# The URL needs every segment. ConfigurationController has two overloads, and the
# one reached without 'service=' passes null straight into the source, which
# throws ArgumentNullException - a 500 on each probe, filling the log with stack
# traces and never going healthy. Found by probing the running container:
#   /Configuration                                          404
#   /Configuration/1/Configuration                          500
#   /Configuration/1/Configuration/service=api.configuration 200
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=20 \
  CMD curl -fsS "http://localhost:8080/Configuration/1/Configuration/service=api.configuration" > /dev/null || exit 1

ENTRYPOINT ["dotnet", "EurofficeGroup.Api.Configuration.Service.dll"]
