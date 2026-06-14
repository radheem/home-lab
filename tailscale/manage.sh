#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"
ENV_FILE=".env"
MANIFEST_FILE="${SCRIPT_DIR}/subnet-lb-only/subnet-router.yaml"
NAMESPACE="tailscale-lb"
SECRET_NAME="tailscale-auth-lb"

# Load environment variables from .env file
load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    else
        echo "⚠️  Warning: .env file not found at $ENV_FILE"
        echo "Please create it with required variables."
        exit 1
    fi
}



usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  install     Deploy Tailscale subnet router"
    echo "  uninstall   Remove Tailscale subnet router"
    echo "  status      Show Tailscale subnet router status"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -k, --authkey       Tailscale auth key (TS_AUTHKEY)"
    echo "  -l, --login-server  Tailscale login server (TS_LOGIN_SERVER)"
    echo "  -c, --cluster-name  Cluster name (CLUSTER_NAME)"
    echo "  -r, --routes        Advertised routes (TS_ROUTES)"
    echo "  -m, --manifest      Manifest file path (MANIFEST_FILE)"
    echo "  -n, --namespace     Kubernetes namespace (NAMESPACE)"
    echo "  -s, --secret-name   Secret name for auth (SECRET_NAME)"
    echo "      --ts-hostname   Tailscale hostname (TS_HOSTNAME)"
    echo "      --cluster-context Kubernetes context (CLUSTER_CONTEXT)"
    echo ""
    echo "Current Configuration (from .env):"
    echo "  CLUSTER_NAME:    $CLUSTER_NAME"
    echo "  CLUSTER_CONTEXT: $CLUSTER_CONTEXT"
    echo "  TS_HOSTNAME:     $TS_HOSTNAME"
    echo "  TS_ROUTES:       $TS_ROUTES"
    echo "  TS_LOGIN_SERVER: $TS_LOGIN_SERVER"
    echo "  NAMESPACE:       $NAMESPACE"
    echo ""
    echo "Examples:"
    echo "  $0 install -c mycluster -k key-abc -l https://login.example -r 10.0.0.0/24"
    echo "  $0 uninstall -c mycluster"
    echo "  $0 status -c mycluster"
    exit 1
}

check_required_vars() {
    local missing=()
    
    [ -z "$TS_AUTHKEY" ] && missing+=("TS_AUTHKEY")
    [ -z "$TS_LOGIN_SERVER" ] && missing+=("TS_LOGIN_SERVER")
    [ -z "$CLUSTER_NAME" ] && missing+=("CLUSTER_NAME")
    [ -z "$TS_ROUTES" ] && missing+=("TS_ROUTES")
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Error: Missing required environment variables:"
        printf '   - %s\n' "${missing[@]}"
        echo ""
        echo "Please set them in $ENV_FILE"
        exit 1
    fi
}

install_tailscale() {
    # Derive TS_HOSTNAME from CLUSTER_NAME
    export TS_HOSTNAME="${CLUSTER_NAME}-ts-router"
    export TS_ROUTES
    CLUSTER_CONTEXT=""
    check_required_vars
    
    echo "🚀 Deploying Tailscale Subnet Router to cluster '$CLUSTER_CONTEXT'..."
    
    # Create the namespace and auth secret
    echo "   - Creating namespace and auth secret..."
    kubectl --context "$CLUSTER_CONTEXT" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl --context "$CLUSTER_CONTEXT" apply -f -
    
    kubectl --context "$CLUSTER_CONTEXT" -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
        --from-literal=authkey="$TS_AUTHKEY" \
        --from-literal=loginServer="$TS_LOGIN_SERVER" \
        --dry-run=client -o yaml | kubectl --context "$CLUSTER_CONTEXT" apply -f -
    
    # Apply the manifest using envsubst to replace the hostname and routes
    echo "   - Applying Kubernetes manifest..."
    envsubst < "$MANIFEST_FILE" | kubectl --context "$CLUSTER_CONTEXT" apply -f -
    
    echo "   - Waiting for Subnet Router deployment to be ready..."
    kubectl --context "$CLUSTER_CONTEXT" -n "$NAMESPACE" wait --for=condition=available deployment/tailscale-subnet-router-lb --timeout=120s
    
    echo ""
    echo "✅ Tailscale Subnet Router deployed successfully!"
    echo "   Hostname:          $TS_HOSTNAME"
    echo "   Advertised routes: $TS_ROUTES"
    echo ""
    echo "⚠️  Don't forget to approve the advertised routes in your Headscale admin console!"
    echo "To check status: $0 status"
}

uninstall_tailscale() {
    echo "🔥 Tearing down Tailscale Subnet Router from cluster '$CLUSTER_CONTEXT'..."
    
    # Delete the manifest resources
    echo "   - Deleting Kubernetes resources..."
    envsubst < "$MANIFEST_FILE" | kubectl --context "$CLUSTER_CONTEXT" delete -f - --ignore-not-found=true
    
    # Delete the secret (created separately)
    echo "   - Deleting auth secret..."
    kubectl --context "$CLUSTER_CONTEXT" delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true
    
    echo ""
    echo "✅ Tailscale Subnet Router teardown complete!"
}

show_status() {
    echo "=== Configuration (from .env) ==="
    echo "  CLUSTER_NAME:    $CLUSTER_NAME"
    echo "  CLUSTER_CONTEXT: $CLUSTER_CONTEXT"
    echo "  TS_HOSTNAME:     $TS_HOSTNAME"
    echo "  TS_ROUTES:       $TS_ROUTES"
    echo "  TS_LOGIN_SERVER: $TS_LOGIN_SERVER"
    echo ""
    
    echo "=== Tailscale Subnet Router Status ==="
    if kubectl --context "$CLUSTER_CONTEXT" get namespace "$NAMESPACE" &>/dev/null; then
        echo "Namespace '$NAMESPACE' exists"
        echo ""
        echo "=== Deployment ==="
        kubectl --context "$CLUSTER_CONTEXT" get deployment -n "$NAMESPACE" 2>/dev/null || echo "No deployments found"
        echo ""
        echo "=== Pods ==="
        kubectl --context "$CLUSTER_CONTEXT" get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "No pods found"
        echo ""
        echo "=== Secrets ==="
        kubectl --context "$CLUSTER_CONTEXT" get secrets -n "$NAMESPACE" 2>/dev/null || echo "No secrets found"
        echo ""
        echo "=== Pod Logs (last 20 lines) ==="
        local pod=$(kubectl --context "$CLUSTER_CONTEXT" get pods -n "$NAMESPACE" -l app=tailscale-subnet-router-lb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$pod" ]; then
            kubectl --context "$CLUSTER_CONTEXT" logs -n "$NAMESPACE" "$pod" --tail=20 2>/dev/null || echo "Cannot retrieve logs"
        else
            echo "No running pods found"
        fi
    else
        echo "Namespace '$NAMESPACE' does not exist. Tailscale subnet router is not installed."
    fi
}

# Parse command
if [ $# -lt 1 ]; then
    usage
fi

COMMAND="$1"
shift

# Parse remaining options (flags expected after the command)
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -k|--authkey)
            TS_AUTHKEY="$2"; shift
            ;;
        -l|--login-server)
            TS_LOGIN_SERVER="$2"; shift
            ;;
        -c|--cluster-name)
            CLUSTER_NAME="$2"; shift
            ;;
        -r|--routes)
            TS_ROUTES="$2"; shift
            ;;
        -m|--manifest)
            MANIFEST_FILE="$2"; shift
            ;;
        -n|--namespace)
            NAMESPACE="$2"; shift
            ;;
        -s|--secret-name)
            SECRET_NAME="$2"; shift
            ;;
        --ts-hostname)
            TS_HOSTNAME="$2"; shift
            ;;
        --cluster-context)
            CLUSTER_CONTEXT="$2"; shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# If a cluster name was provided but no explicit context, derive it
if [ -z "$CLUSTER_CONTEXT" ] && [ -n "$CLUSTER_NAME" ]; then
    CLUSTER_CONTEXT="$CLUSTER_NAME"
fi

# If TS_HOSTNAME not provided, derive from CLUSTER_NAME
if [ -z "$TS_HOSTNAME" ] && [ -n "$CLUSTER_NAME" ]; then
    TS_HOSTNAME="${CLUSTER_NAME}-ts-router"
fi

# Execute command
case "$COMMAND" in
    install)
        install_tailscale
        ;;
    uninstall)
        uninstall_tailscale
        ;;
    status)
        show_status
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        ;;
esac
