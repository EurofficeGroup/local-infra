# One Dockerfile for all the small EurofficeGroup APIs: tax, pricing, product
# (which also serves DeliveryCharge), audience and payments.
#
# They are the same shape. Each is a net8.0 generic host whose Program.cs ends in
#
#     .ConfigureEoWebHostUsingStartup<Startup>("api.tax", "TaxApiPort")
#
# so the service reads its own port from a configuration key, and everything else
# - connection strings, transport, cache - from the Configuration API at
# ConfigurationUrl. Exactly like api.configuration, which is why this file is a
# near copy of api-configuration.Dockerfile.
#
# Build context is the repo root (C:\workspace\api.tax and friends). Compose
# passes the two things that differ:
#
#     PROJECT  src/EurofficeGroup.Api.Tax   (folder; the csproj inside matches)
#     ENTRY    EurofficeGroup.Api.Tax.dll
#     PORT     9005
#
# The port key itself (TaxApiPort, PricingApiPort, ...) is a plain environment
# variable set by compose, since its NAME differs per service and a Dockerfile
# cannot set a variable whose name is an argument.
#
# The port numbers are not ours to choose - WebConfigPicker writes them into the
# IIS sites' web.config (MainWindow.xaml.cs, UseLocal* branches), so a container
# has to listen where the sites already look.

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

WORKDIR /src
# These repos keep NuGet.Config in .nuget/, which NuGet's parent-directory
# discovery does not look inside. Copy it where restore will find it.
COPY .nuget/NuGet.Config ./NuGet.Config
COPY src/ src/

ARG PROJECT
ARG BUILD_CONFIG=Release

RUN dotnet publish "$PROJECT" -c "$BUILD_CONFIG" -o /app --no-self-contained

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final

# curl for the healthcheck only: the aspnet image has neither curl nor wget, and
# its /bin/sh is dash, which has no /dev/tcp.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app /app

ARG PORT
ARG ENTRY
ENV API_PORT=${PORT}
ENV API_ENTRY=${ENTRY}
EXPOSE ${PORT}

# No -f: these APIs have no agreed health route, and their root answers 404.
# A 404 still proves the process is up, listening and serving HTTP, which is all
# the dependent containers need to know. -f would turn that into a failure.
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=20 \
  CMD curl -s -o /dev/null "http://localhost:${API_PORT}/" || exit 1

# ENTRY is the published assembly name, e.g. EurofficeGroup.Api.Tax.dll. It has
# to go through a shell because it is a build argument; exec keeps dotnet as
# PID 1 so compose's SIGTERM reaches it and the container stops promptly.
ENTRYPOINT ["sh", "-c", "exec dotnet \"$API_ENTRY\""]
