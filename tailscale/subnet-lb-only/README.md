# Tailscale Subnet Router (LoadBalancer-Only Mode)

This directory contains an implementation for deploying a Tailscale subnet router that is specifically configured to **only advertise the IP address range used by MetalLB**.

This aligns with an architectural choice where only services of `type: LoadBalancer` are made accessible to the Tailnet.

## Architecture

1.  **Dynamic Configuration:** The MetalLB IP range and other cluster-specific settings are now dynamically configured from the root `.env` file.
2.  **`Deployment`:** A simple `Deployment` runs the Tailscale client. It does not require any special RBAC permissions for discovery.

This means that only services that acquire an IP address from the MetalLB pool (defined by `LB_IP_RANGE` in your `.env` file) will be reachable from your Tailnet.

## How to Use

1.  **Configure `.env`:** Ensure that your root `.env` file is correctly configured with your Tailscale auth key (`TS_AUTHKEY`) and other necessary variables.

2.  **Run the Setup Script:** From the root of the project, run the `setup.sh` script located in this directory:

    ```bash
    bash tailscale/subnet-lb-only/setup.sh
    ```

3.  **IMPORTANT: Approve the Routes:**
    - Go to your Tailscale/Headscale Admin Console and find the new machine (the hostname is dynamically generated based on your `CLUSTER_NAME`, e.g., `qube-genai-ts-router`).
    - Select `Edit route settings...` and **approve** the advertised route, which will be the value of `TS_ROUTES` from your `.env` file.

## Verification

To test this setup, you can deploy a service of `type: LoadBalancer`. The test manifests in this directory are configured for this.

1.  **Deploy the test service:**

    ```bash
    kubectl apply -f tailscale/subnet-lb-only/test-http-lb.yaml
    ```

2.  **Get the service's external IP:**

    ```bash
    kubectl get svc http-test-lb-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    ```

3.  **Test from another Tailnet machine:**

    From another machine on your Tailnet, use `curl` to access the service at the external IP address obtained in the previous step.

    ```bash
    curl http://<external-ip>
    ```

    You should see the "Welcome to nginx!" message.

4.  **Clean up:**

    ```bash
    kubectl delete -f tailscale/subnet-lb-only/test-http-lb.yaml
    ```
