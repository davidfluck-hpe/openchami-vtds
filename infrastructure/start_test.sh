#
# MIT License
#
# (C) Copyright 2026 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

function image_tag() {
    echo "${OPENCHAMI_VERSION}" | md5sum | cut -c 1-10
}

: "${TEST_REPO_URL:="git@github.com:davidfluck-hpe/openchami-vtds.git"}"
: "${TEST_REPO_TREE:="$(pwd)/openchami-vtds"}"
: "${GITHUB_KEY_SECRET_NAME:="github-df-deploy-key"}"
: "${OPENCHAMI_VERSION:="main"}"  # This should be in the environment
: "${CONTAINER_IMAGE_TAG:="$(image_tag)"}"
export OPENCHAMI_VERSION

INFRASTRUCTURE_PATH="${TEST_REPO_TREE}/infrastructure"

# Set up keys for access to the GitHub test repository
mkdir -p ~/.ssh
touch ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
gcloud secrets versions access latest \
       --secret="${GITHUB_KEY_SECRET_NAME}" > ~/.ssh/id_rsa

# Clone the repository so we have access to the infrastructure needed
# to start testing
git clone "${TEST_REPO_URL}" "${TEST_REPO_TREE}"

# Build the Podman container image and start the tests in it
cd "${INFRASTRUCTURE_PATH}"

# First clean up any images that have not been used in the past 24
# hours so we keep things resonably tidy
podman images prune -a --filter "until=24h"

# Now create our image
podman build -t "openchami-tester:${CONTAINER_IMAGE_TAG}" .
podman run \
       -e OPENCHAMI_VERSION \
       -e TEST_TIMESTAMP \
       -e TEST_REPO_URL \
       -e TEST_REPO_TREE \
       -e OPENCHAMI_VERSION \
       -e TEST_RUN_NAME \
       -e TEST_CLUSTER_NAME \
       -e TEST_UPDATE_INTERVAL \
       -e TEST_DEPLOY_TIMEOUT \
       -e TEST_REMOVE_TIMEOUT \
       -e VTDS_CONFIG_TEMPLATE \
       -e GITHUB_KEY_SECRET_NAME \
       -d "openchami-tester:${CONTAINER_IMAGE_TAG}"

# Clean up...
rm -rf "${TEST_REPO_TREE}"

# The test is now running so we are done
exit 0
