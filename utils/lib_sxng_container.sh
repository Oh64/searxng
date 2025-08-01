#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later

container.help() {
    cat <<EOF
container.:
  build     : build container image
EOF
}

CONTAINER_IMAGE_ORGANIZATION=${GITHUB_REPOSITORY_OWNER:-"oh64"}
DOCKER_IMAGE_ORGANIZATION=${DOCKER_REPOSITORY_OWNER:-"oh64chan"}
CONTAINER_IMAGE_NAME="searxng"

container.build() {
    local parch=${OVERRIDE_ARCH:-$(uname -m)}
    local container_engine
    local dockerfile
    local arch
    local variant
    local platform

    required_commands git

    # Check if podman or docker is installed
    if [ "$1" = "podman" ] || [ "$1" = "docker" ]; then
        if ! command -v "$1" &>/dev/null; then
            die 42 "$1 is not installed"
        fi
        container_engine="$1"
    else
        # If no explicit engine is passed, prioritize podman over docker
        if command -v podman &>/dev/null; then
            container_engine="podman"
        elif command -v docker &>/dev/null; then
            container_engine="docker"
        else
            die 42 "no compatible container engine is installed (podman or docker)"
        fi
    fi
    info_msg "Selected engine: $container_engine"

    # Setup arch specific
    case $parch in
        "X64" | "x86_64" | "amd64")
            dockerfile="Dockerfile"
            arch="amd64"
            variant=""
            platform="linux/$arch"
            ;;
        "ARM64" | "aarch64" | "arm64")
            dockerfile="Dockerfile"
            arch="arm64"
            variant=""
            platform="linux/$arch"
            ;;
        "ARMV7" | "armhf" | "armv7l" | "armv7")
            dockerfile="Dockerfile"
            arch="arm"
            variant="v7"
            platform="linux/$arch/$variant"
            ;;
        *)
            err_msg "Unsupported architecture; $parch"
            exit 1
            ;;
    esac
    info_msg "Selected platform: $platform"

    pyenv.install

    (
        set -e
        pyenv.activate

        # Check if it is a git repository
        if [ ! -d .git ]; then
            die 1 "This is not Git repository"
        fi

        if ! git remote get-url origin &>/dev/null; then
            die 1 "There is no remote origin"
        fi

        # This is a git repository
        git update-index -q --refresh
        python -m searx.version freeze
        eval "$(python -m searx.version)"

        info_msg "Set \$VERSION_STRING: $VERSION_STRING"
        info_msg "Set \$VERSION_TAG: $VERSION_TAG"
        info_msg "Set \$DOCKER_TAG: $DOCKER_TAG"
        info_msg "Set \$GIT_URL: $GIT_URL"
        info_msg "Set \$GIT_BRANCH: $GIT_BRANCH"

        if [ "$container_engine" = "podman" ]; then
            params_build_builder="build --format=oci --platform=$platform --target=builder --layers --identity-label=false"
            params_build="build --format=oci --platform=$platform --layers --squash-all --omit-history --identity-label=false"
        else
            params_build_builder="build --platform=$platform --target=builder"
            params_build="build --platform=$platform --squash"
        fi

        if [ "$GITHUB_ACTIONS" = "true" ]; then
            params_build_builder+=" --cache-from=ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache --cache-to=ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache"

            # Tags
            params_build+=" --tag=ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache:$CONTAINER_IMAGE_NAME-$arch$variant"
        else
            # Tags
            params_build+=" --tag=localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:latest"
            params_build+=" --tag=localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$DOCKER_TAG"
        fi

        # shellcheck disable=SC2086
        "$container_engine" $params_build_builder \
            --build-arg="TIMESTAMP_SETTINGS=$(git log -1 --format="%cd" --date=unix -- ./searx/settings.yml)" \
            --tag="localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:builder" \
            --file="./container/$dockerfile" \
            .
        build_msg CONTAINER "Image \"builder\" built"

        # shellcheck disable=SC2086
        "$container_engine" $params_build \
            --build-arg="TIMESTAMP_SETTINGS=$(git log -1 --format="%cd" --date=unix -- ./searx/settings.yml)" \
            --build-arg="GIT_URL=$GIT_URL" \
            --build-arg="SEARXNG_GIT_VERSION=$VERSION_STRING" \
            --build-arg="LABEL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --build-arg="LABEL_VCS_REF=$(git rev-parse HEAD)" \
            --build-arg="LABEL_VCS_URL=$GIT_URL" \
            --file="./container/$dockerfile" \
            .
        build_msg CONTAINER "Image built"

        if [ "$GITHUB_ACTIONS" = "true" ]; then
            "$container_engine" push "ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache:$CONTAINER_IMAGE_NAME-$arch$variant"

            # Output to GHA
            cat <<EOF >>"$GITHUB_OUTPUT"
version_string=$VERSION_STRING
version_tag=$VERSION_TAG
docker_tag=$DOCKER_TAG
git_url=$GIT_URL
git_branch=$GIT_BRANCH
EOF
        fi
    )
    dump_return $?
}

container.test() {
    local parch=${OVERRIDE_ARCH:-$(uname -m)}
    local arch
    local variant
    local platform

    if [ "$GITHUB_ACTIONS" != "true" ]; then
        die 1 "This command is intended to be run in GitHub Actions"
    fi

    required_commands podman

    # Setup arch specific
    case $parch in
        "X64" | "x86_64" | "amd64")
            arch="amd64"
            variant=""
            platform="linux/$arch"
            ;;
        "ARM64" | "aarch64" | "arm64")
            arch="arm64"
            variant=""
            platform="linux/$arch"
            ;;
        "ARMV7" | "armhf" | "armv7l" | "armv7")
            arch="arm"
            variant="v7"
            platform="linux/$arch/$variant"
            ;;
        *)
            err_msg "Unsupported architecture; $parch"
            exit 1
            ;;
    esac
    build_msg CONTAINER "Selected platform: $platform"

    (
        set -e

        podman pull "ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache:$CONTAINER_IMAGE_NAME-$arch$variant"

        name="$CONTAINER_IMAGE_NAME-$(date +%N)"

        podman create --name="$name" --rm --timeout=60 --network="host" \
            "ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache:$CONTAINER_IMAGE_NAME-$arch$variant" >/dev/null

        podman start "$name" >/dev/null
        podman logs -f "$name" &
        pid_logs=$!

        # Wait until container is ready
        sleep 5

        curl -vf --max-time 5 "http://localhost:8080/healthz"

        kill $pid_logs &>/dev/null || true
        podman stop "$name" >/dev/null
    )
    dump_return $?
}

container.push() {
    # Architectures on manifest
    local release_archs=("amd64" "arm64" "armv7")

    local archs=()
    local variants=()
    local platforms=()

    if [ "$GITHUB_ACTIONS" != "true" ]; then
        die 1 "This command is intended to be run in GitHub Actions"
    fi

    required_commands podman

    for arch in "${release_archs[@]}"; do
        case $arch in
            "X64" | "x86_64" | "amd64")
                archs+=("amd64")
                variants+=("")
                platforms+=("linux/${archs[-1]}")
                ;;
            "ARM64" | "aarch64" | "arm64")
                archs+=("arm64")
                variants+=("")
                platforms+=("linux/${archs[-1]}")
                ;;
            "ARMV7" | "armv7" | "armhf" | "arm")
                archs+=("arm")
                variants+=("v7")
                platforms+=("linux/${archs[-1]}/${variants[-1]}")
                ;;
            *)
                err_msg "Unsupported architecture; $arch"
                exit 1
                ;;
        esac
    done

    (
        set -e

        # Pull archs
        for i in "${!archs[@]}"; do
            podman pull "ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache:$CONTAINER_IMAGE_NAME-${archs[$i]}${variants[$i]}"
        done

        # Manifest tags
        release_tags=("latest" "$DOCKER_TAG")

        # Create manifests
        for tag in "${release_tags[@]}"; do
            if ! podman manifest exists "localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$tag"; then
                podman manifest create "localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$tag"
            fi

            # Add archs to manifest
            for i in "${!archs[@]}"; do
                podman manifest add \
                    "localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$tag" \
                    "containers-storage:ghcr.io/$CONTAINER_IMAGE_ORGANIZATION/cache:$CONTAINER_IMAGE_NAME-${archs[$i]}${variants[$i]}"
            done
        done

        podman image list

        # Remote registries
        release_registries=("ghcr.io" "docker.io")

        # Push manifests
        for registry in "${release_registries[@]}"; do
            for tag in "${release_tags[@]}"; do
                build_msg CONTAINER "Pushing manifest $tag to $registry"

                if [ "$registry" = "docker.io" ]; then
                    podman manifest push \
                        "localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$tag" \
                        "docker://$registry/$DOCKER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$tag"
                else
                    podman manifest push \
                        "localhost/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$tag" \
                        "docker://$registry/$CONTAINER_IMAGE_ORGANIZATION/$CONTAINER_IMAGE_NAME:$tag"
                fi
            done
        done
    )
    dump_return $?
}

# Alias
podman.build() {
    container.build podman
}

# Alias
docker.build() {
    container.build docker
}

# Alias
docker.buildx() {
    container.build docker
}
