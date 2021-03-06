#!/bin/bash

set -e

# creates a client CA, args are sudo, dest-dir, ca-id, purpose
# purpose is dropped in after "key encipherment", you usually want
# '"client auth"'
# '"server auth"'
# '"client auth","server auth"'
function kube::util::create_signing_certkey {
    local sudo=$1
    local dest_dir=$2
    local id=$3
    local purpose=$4
    # Create client ca
    ${sudo} /bin/bash -e <<EOF
    rm -f "${dest_dir}/${id}-ca.crt" "${dest_dir}/${id}-ca.key"
    openssl req -x509 -sha256 -new -nodes -days 365 -newkey rsa:2048 -keyout "${dest_dir}/${id}-ca.key" -out "${dest_dir}/${id}-ca.crt" -subj "/C=xx/ST=x/L=x/O=x/OU=x/CN=ca/emailAddress=x/"
    echo '{"signing":{"default":{"expiry":"43800h","usages":["signing","key encipherment",${purpose}]}}}' > "${dest_dir}/${id}-ca-config.json"
EOF
}

# signs a serving certificate: args are sudo, dest-dir, ca, filename (roughly), subject, hosts...
function kube::util::create_serving_certkey {
    local sudo=$1
    local dest_dir=$2
    local ca=$3
    local id=$4
    local cn=${5:-$4}
    local hosts=""
    local SEP=""
    shift 5
    while [ -n "${1:-}" ]; do
        hosts+="${SEP}\"$1\""
        SEP=","
        shift 1
    done
    ${sudo} /bin/bash -e <<EOF
    cd ${dest_dir}
    echo '{"CN":"${cn}","hosts":[${hosts}],"key":{"algo":"rsa","size":2048}}' | cfssl gencert -ca=${ca}.crt -ca-key=${ca}.key -config=${ca}-config.json - | cfssljson -bare serving-${id}
    mv "serving-${id}-key.pem" "serving-${id}.key"
    mv "serving-${id}.pem" "serving-${id}.crt"
    rm -f "serving-${id}.csr"
EOF
}

CERT_DIR=_output/tmp/certs
mkdir -p "${CERT_DIR}"

kube::util::create_signing_certkey "" "${CERT_DIR}" serving '"server auth"'
kube::util::create_serving_certkey "" "${CERT_DIR}" "serving-ca" server.openshift-namespace-reservation.svc "server.openshift-namespace-reservation.svc" "server.openshift-namespace-reservation.svc"

kubectl create ns openshift-namespace-reservation || true
kubectl auth reconcile -f artifacts/kube-install/rbac-list.yaml
cat artifacts/kube-install/apiserver-list.yaml | \
sed "s/TLS_SERVING_CERT/$(base64 ${CERT_DIR}/serving-server.openshift-namespace-reservation.svc.crt -w0)/g" - | \
sed "s/TLS_SERVING_KEY/$(base64 ${CERT_DIR}/serving-server.openshift-namespace-reservation.svc.key -w0)/g" - | \
sed "s/SERVICE_SERVING_CERT_CA/$(base64 ${CERT_DIR}/serving-ca.crt -w0)/g" - | \
sed "s/KUBE_CA/$(base64 /var/run/kubernetes/server-ca.crt -w0)/g" - | \
kubectl apply -f -
