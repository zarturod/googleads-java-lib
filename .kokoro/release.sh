#!/bin/bash
set -euo pipefail

# ==============================================================================
# SECURITY NOTICE: DO NOT ADD 'set -x' TO THIS SCRIPT!
# This script handles PGP signing keys and passphrases from Secret Manager.
# ==============================================================================
set +x

DRY_RUN="${DRY_RUN:-true}"
if [[ "${DRY_RUN}" != "true" && "${DRY_RUN}" != "false" ]]; then
  echo "ERROR: DRY_RUN must be 'true' or 'false' (got '${DRY_RUN}')." >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

echo "=== Building and Releasing from: ${REPO_DIR} (DRY_RUN=${DRY_RUN}) ==="

if [[ ! -d "/usr/lib/jvm/java-17-openjdk-amd64" ]]; then
  echo "ERROR: Kokoro worker missing expected OpenJDK 17 at /usr/lib/jvm/java-17-openjdk-amd64" >&2
  exit 1
fi
export PATH="/usr/lib/jvm/java-17-openjdk-amd64/bin:${PATH}"
unset JAVA_HOME

EXIT_GATE_PROJECT="oss-exit-gate-prod"
EXIT_GATE_LOCATION="us"
EXIT_GATE_REPOSITORY="googleads-java-lib--mavencentral"

PACKAGES=(
  "client-libs-parent"
  "ads-lib"
  "ads-lib-appengine"
  "ads-lib-axis"
  "dfp-appengine"
  "dfp-axis"
)

for pkg in "${PACKAGES[@]}"; do
  full_pkg="com.google.api-ads:${pkg}"
  if gcloud artifacts packages describe "${full_pkg}" \
      --project="${EXIT_GATE_PROJECT}" \
      --location="${EXIT_GATE_LOCATION}" \
      --repository="${EXIT_GATE_REPOSITORY}" &>/dev/null; then
    echo "=== Deleting existing package '${full_pkg}' from Exit Gate staging repository ==="
    gcloud artifacts packages delete "${full_pkg}" \
      --project="${EXIT_GATE_PROJECT}" \
      --location="${EXIT_GATE_LOCATION}" \
      --repository="${EXIT_GATE_REPOSITORY}" \
      --quiet
  fi
done

if [[ -z "${SIGNING_KEY:-}" ]]; then
  export SIGNING_KEY="$(gcloud secrets versions access latest \
    --secret="bam-devrel-maven-gpg-key" \
    --project="bam-devrel-releases" 2>/dev/null || \
    gcloud secrets versions access latest \
    --secret="google_ads_java_gpg_secring" \
    --project="bam-devrel-releases")"
fi

if [[ -z "${SIGNING_PASSWORD:-}" ]]; then
  export SIGNING_PASSWORD="$(gcloud secrets versions access latest \
    --secret="bam-devrel-maven-gpg-password" \
    --project="bam-devrel-releases" 2>/dev/null || \
    gcloud secrets versions access latest \
    --secret="google_ads_java_gpg_passphrase" \
    --project="bam-devrel-releases" 2>/dev/null || true)"
fi

export GNUPGHOME="$(mktemp -d)"
chmod 700 "${GNUPGHOME}"
SETTINGS_XML="$(mktemp --suffix=.xml)"
trap 'rm -rf "${GNUPGHOME}" "${SETTINGS_XML}"' EXIT

printf '%s' "${SIGNING_KEY}" | gpg --batch --import

ACCESS_TOKEN="$(gcloud auth print-access-token)"
cat <<EOF > "${SETTINGS_XML}"
<settings>
  <servers>
    <server>
      <id>exit-gate</id>
      <username>oauth2accesstoken</username>
      <password>${ACCESS_TOKEN}</password>
    </server>
  </servers>
</settings>
EOF
unset ACCESS_TOKEN

mvn clean org.apache.maven.plugins:maven-deploy-plugin:2.8.2:deploy \
  --settings "${SETTINGS_XML}" \
  -DperformRelease=true \
  -Dgpg.passphrase="${SIGNING_PASSWORD}" \
  -DaltDeploymentRepository="exit-gate::default::https://us-maven.pkg.dev/${EXIT_GATE_PROJECT}/${EXIT_GATE_REPOSITORY}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "=== DRY_RUN is enabled. Artifacts staged in Artifact Registry. ==="
  exit 0
fi

cat <<EOF > manifest.json
{
  "publish_all": false,
  "publishing_groups": [
    {
      "namespace": "com.google.api-ads",
      "packages": [
        { "name": "client-libs-parent" },
        { "name": "ads-lib" },
        { "name": "ads-lib-appengine" },
        { "name": "ads-lib-axis" },
        { "name": "dfp-appengine" },
        { "name": "dfp-axis" }
      ]
    }
  ]
}
EOF

EXIT_GATE_BUCKET="gs://oss-exit-gate-prod-projects-bucket/googleads-java-lib/mavencentral/manifests"
MANIFEST_NAME="manifest-$(date --utc +%Y%m%d%H%M%S'UTC').json"

echo "=== Uploading manifest to ${EXIT_GATE_BUCKET}/${MANIFEST_NAME} ==="
gcloud storage cp manifest.json "${EXIT_GATE_BUCKET}/${MANIFEST_NAME}"
