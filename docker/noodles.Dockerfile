# One image, every Noodles service inside it.
#
# Build context is C:\workspace\noodles.
#
# Why one image rather than sixteen: the services share almost all of their
# dependencies, so sixteen images would restore and compile the same trees over
# and over. Here the restore happens once and each compose service just runs a
# different DLL. Building one service alone is not a thing you need - running
# one alone is, and that is a compose concern, not an image concern.
#
# The services target net8.0 and call .UseSystemd() alongside .UseWindowsService(),
# so Linux is an intended host, not a workaround.

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

# The internal feed is plain HTTP, and this NuGet.Config already allows that.
# Restoring needs the VPN to be up on the host.
# Both repos' configs list only the internal 'eo' feed and neither uses <clear/>,
# so nuget.org still comes from the SDK image's own user-level config through
# NuGet's hierarchical merge. If a restore ever fails with a package that should
# come from nuget.org, that merge is what broke - add nuget.org here explicitly.
WORKDIR /src
COPY NuGet.Config ./

# Project files first, so a code change does not invalidate the restore layer.
COPY src/ src/
# JSON form: the path contains a space, and the shell form cannot express that.
COPY ["NServiceBus License/", "NServiceBus License/"]

ARG BUILD_CONFIG=Release

# Publish every executable service into its own folder. The list is explicit:
# the library projects (Noodles.Domain, Noodles.Configuration, ...) are built as
# dependencies and must not get their own output.
RUN set -eux; \
    for p in \
        Noodles.Actions \
        Noodles.Ai \
        Noodles.Audience \
        Noodles.Catalogues \
        Noodles.Email \
        Noodles.Finance \
        Noodles.Inventory \
        Noodles.Marketing \
        Noodles.Pdf \
        Noodles.Reporting \
        Noodles.Sales \
        Noodles.ScheduleCoordinator \
        Noodles.Segmentation \
        Noodles.Statistics \
        Noodles.Transport \
        Noodles.Uploaders \
    ; do \
        dotnet publish "src/$p/$p.csproj" \
            -c "$BUILD_CONFIG" \
            -o "/app/$p" \
            --no-self-contained; \
    done

# ----------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/runtime:8.0 AS final

# Console hosts, not web hosts - the runtime image is enough.
WORKDIR /app
COPY --from=build /app /app

# Which service this container runs. Compose overrides it per service.
ENV NOODLES_SERVICE=Noodles.Sales

# Set by compose; listed here so the image documents what it expects.
ENV DOTNET_ENVIRONMENT=Development

# exec so the app is PID 1 and receives SIGTERM directly - otherwise
# `docker compose stop` waits out the timeout and kills it.
ENTRYPOINT ["/bin/sh", "-c", "exec dotnet \"/app/$NOODLES_SERVICE/$NOODLES_SERVICE.dll\""]
