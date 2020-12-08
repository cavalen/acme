# NGINX Service Mesh: Lesson 1

## System setup

### Expose the following HTTPS ports in k8s1 via the deploy GUI. 
If you are using the official blueprint these have already been exposed, but if you
are building a new blueprint or deployment you will need to manually
expose the following:. 

- Prometheus: 9090
- Grafana: 3000
- Bookinfo Product Page: 9080
- Zipkin: 9411

### Familiarize yourself with a local registry:

*Local registry is `registry:5000`*. 

The below is a quick walkthrough on using the local registry.  It is not
required for NSM, simply some background on using a local registry with K8s
(which you will be using for your NSM deployment).

```shell
$ docker pull nginx
$ docker tag nginx:latest registry:5000/nginx:latest
$ docker push registry:5000/nginx:latest
$ wget https://raw.githubusercontent.com/kubernetes/website/master/content/en/examples/application/deployment.yaml
$ vim deployment.yaml
```

*Change image to `registry:5000/nginx:latest`*

```shell
$ kubectl apply -f ./deployment.yaml
$ kubectl get pods
$ kubectl describe pod/deployment-[GUID]
```

*Look for `Successfully pulled image "registry:5000..."` to make sure the local reg is working*

```shell
$ kubectl delete -f ./deployment.yaml
```

## Deploy NSM

### Set it up

```shell
$ export ver=0.6.0
$ gzip -dc nginx-meshctl_linux > nginx-meshctl && chmod 755 nginx-meshctl
$ tar zxvf nginx-mesh-images-0.6.0.tar.gz
```

### Load images into local repo:

```shell
$ docker load < nginx-mesh-images-$ver/nginx-mesh-api-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-metrics-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-sidecar-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-init-$ver.tar.gz
```

### Re-tag to load into registry:5000

```shell
$ docker tag nginx-mesh-sidecar:$ver registry:5000/nginx-mesh-sidecar:$ver && \
        docker tag nginx-mesh-init:$ver registry:5000/nginx-mesh-init:$ver && \
        docker tag nginx-mesh-metrics:$ver registry:5000/nginx-mesh-metrics:$ver && \
        docker tag nginx-mesh-api:$ver registry:5000/nginx-mesh-api:$ver
```

### Push newly tagged containers into registry:5000

```shell
$ docker push registry:5000/nginx-mesh-api:$ver && \
        docker push registry:5000/nginx-mesh-metrics:$ver && \
        docker push registry:5000/nginx-mesh-init:$ver && \
        docker push registry:5000/nginx-mesh-sidecar:$ver
```

### Verify all images are avail and ready for the mesh

```shell
$ docker image ls | grep "registry:5000/nginx-mesh"
```

## Deploy the mesh. 
*This walkthrough will disable auto-injection cluster-wide and enable the `bookinfo` namespace for auto-inect only. We will look at how to change this behavior after NSM is deployed later in the lesson.*

```shell
$ ./nginx-meshctl deploy \
        --disable-auto-inject \
        --enabled-namespaces bookinfo \
        --mtls-mode strict \
        --nginx-mesh-api-image "registry:5000/nginx-mesh-api:$ver" \
        --nginx-mesh-sidecar-image "registry:5000/nginx-mesh-sidecar:$ver" \
        --nginx-mesh-init-image "registry:5000/nginx-mesh-init:$ver" \
        --nginx-mesh-metrics-image "registry:5000/nginx-mesh-metrics:$ver"
```

### Check that auto-injection is disabled for the entire cluster by default but enabled for `bookinfo`

```shell
$ ./nginx-meshctl config | jq '.injection'

---
{
        "disabledNamespaces": [],
        "enabledNamespaces": [
                "bookinfo"
                ],
        "isAutoInjectEnabled": false
}
---
```

## Start Testing

### Deploy bookinfo first then inject and re-deploy

```shell
$ wget https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml
$ kubectl create namespace bookinfo
$ kubectl apply -f ./bookinfo.yaml -n bookinfo
$ kubectl get pods -n bookinfo
```

*Pod status should eventually show `Running` and `Ready` should show `2/2` for each pod*

### List containers in every pod in bookinfo to show that pods have been deployed w nginx-mesh sidecars

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*The above command will display a list of each container running in each pod
in namespace `bookinfo`.  You want to look for both the bookinfo application
container and the NSM sidecar container in each pod.  For example, you
should see something like `details-v1-74f858558f-69lll:
docker.io/istio/examples-bookinfo-details-v1:1.15.0,
registry:5000//nginx-mesh-sidecar:0.6.0,"*

### Demo enabled namespaces by deploying `bookinfo` in a namespace not on configured for NSM auto-injection

```shell
$ kubectl create namespace bookinfo-no-inject
$ kubectl apply -f ./bookinfo.yaml -n bookinfo-no-inject
$ kubectl get pods -n bookinfo-no-inject
```

*Pod status should eventually show `Running` and `Ready` should show `1/1` for each pod, showing that the mesh did not inject a sidecar into the same deployment*

### Create manual injection config and inject to namespace that's not enabled for auto-injection

```shell
$ kubectl create namespace bookinfo-man-inject
$ ./nginx-meshctl inject < bookinfo.yaml > bookinfo-man-inject.yaml
$ kubectl apply -f ./bookinfo-man-inject.yaml -n bookinfo-man-inject
$ kubectl get pods -n bookinfo-man-inject
```

*Pod status should eventually show Running and Ready should show `2/2` for each pod, showing that we created a manual injection app deployment and deployed that into a namespace that is not enabled for auto-injection but we still manage it from what we've added to the deployment.*

 ### Show injected sidecar container details

```shell
$ kubectl get pods -n bookinfo-man-inject -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl describe pod/$(kubectl get pod -l app=productpage -n bookinfo-man-inject -o jsonpath='{.items[0].metadata.name}') -n bookinfo-man-inject
```

*Similar to the above, the goal is to show that the NSM sidecar proxies have
been injected into the bookinfo app in a namespace that is not configured
for auto-inject.  This means that NSM is still managing traffic for the
bookinfo app in the unmanaged namespace `bookinfo-man-inject`.*

### Review manual injection details

```shell
$ diff bookinfo.yaml bookinfo-man-inject.yaml
```

*The diff will show that the new deployment, `bookinfo-man-inject.yaml`,
contains new specifications for injecting the NSM sidecar into each
application.  You are able to deploy this new NSM-managed application
deployment in any cluster where NSM is running, regardless of namespace.*

### List all services managed by the mesh

```shell
$ ./nginx-meshctl services
```

*Will return each service in the form of `namespace/service <ip_address> <port>`*

  
## Working with NSM, bookinfo, and scale examples 

### Simple connection to show sidecar is handling traffic

```shell
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*When NSM is configured with `mTLS strict`, the easiest way to test that
traffic flowing through each sidecar is to exec into one application
container, a `ratings` pod in this case, and connect to another app service
also managed by the mesh, `productpage`.  You will see the
`X-Mesh-Request-ID` header is appended by the egress sidecar, showing
traffic from ratings to productpage was managed by the mesh.*

### More manual way to test live traffic

```shell
$ kubectl port-forward -n bookinfo --address=0.0.0.0 svc/productpage 9080:9080&
```

- Call `https://<your_k8s_cli_image>:9080/productpage?u=normal` in your browser of choice

*NOTE: If you're using UDF and you've exposed port 9080 (which is exposed in
the default blueprint), you don't need to append the port to the URL, simply
use the exposed service URL from the UDF Access Methods GUI.*

*NOTE: Due to the way K8s handles port-forwards (which bypass init
iptables), you can't connect directly to productpages through the mesh
unless you're deploying N+ KIC.  Direct access should only be used to test
and to generate load (as traffic behind product pages will still be tagged
as mesh traffic for top, etc).  For more info on port-forward and iptables:
https://discuss.istio.io/t/how-does-kubectl-port-forward-bypass-envoy-mtls-enforcement/731/2*

### Generate traffic for later 

```shell
$ while true; do curl -I http://localhost:9080/productpage?u=normal; done
```

*From one of your UDF K8s nodes, the above command will generate simple GET
traffic into the mesh which will generate traffic flow through the various
microservice containers within bookinfo.*

### Show Grafana and Top

```shell
$ kubectl port-forward -n nginx-mesh --address=0.0.0.0 svc/grafana 3000:3000&
$ while true; do ./nginx-meshctl top pods -n bookinfo; sleep 1; done
```

- Call `https://<your_k8s_cli_image>:3000` to review the Grafana dashboard

*The first command will expose the Grafana service port so that it can be
access remotely via the previously exposed port in UDF Access Methods.  The
second command will loop the `nginx-meshctl top` command to show that NSM is
seeing and distributing the inter-service traffic between application pods.*

*NOTE: While it is possible to run both `while` traffic generators from the
same K8s instance by running each in the background (which can be managed
using standard *nix tools like `jobs` and/or `fg`), it is generally easier
to run the `nginx-meshctl top` loop from the node where you've installed NSM
and the traffic generator from another node.*

### Kill a pod to show the drop in Grafana and Top

```shell
$ kubectl delete pod/$(kubectl get pod -l app=reviews,version=v3 -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo
$ kubectl get pods -n bookinfo
```

*From another node in the cluster, delete the reviews pod so that K8s has to
re-generate the pod.  NSM will detect the re-gen and pick up traffic
management as soon as the pod becomes available.  Continue watching the
`nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods
become available.*

### Scale to show injection is constant

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*
  
### Scale back down

```shell
$ kubectl scale deployments ratings-v1 --replicas=1 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*

### To see/review NGINX config, exec into the sidecar

```shell
$ kubectl exec $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -c nginx-mesh-sidecar -n bookinfo -it -- cat /etc/nginx/nginx.conf
```
  
## Update NSM config and behavior

### Add two new namespaces: One with auto-inject enabled and one without (for testing manual injection), both used to test the mesh.

```shell
$ kubectl create namespace test-tools-injected
$ kubectl create namespace test-tools
```

### Query NSM API for autoinjection namespace data

```shell
$ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'
```

### Enable API and test by querying the auto-injection namespace allowlist

```shell
$ kubectl port-forward -n nginx-mesh svc/nginx-mesh-api 8443:443&
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

### Change auto-injection allowlist to include a new namespace via JSON payload to API

```shell
$ cat <<EOF > update-namespaces.json
{
        "op": "replace",
        "field": {
        "injection": {
                "isAutoInjectEnabled": false,
                "enabledNamespaces": ["bookinfo", "test-tools-injected"]
                }
        }
}
EOF

$ curl -vkX PATCH --header "Content-Type: application/json" https://localhost:8443/api/config -d @update-namespaces.json
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

*Or use CLI: $ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'*

## Remove NSM

*NOTE: Removing the mesh removes the control plane but not the data plane; sidecars stay in place but are reconfigured as transparent sidecars with no security or routing policies.*

### Remove NSM control plane

```shell
$ ./nginx-meshctl remove -y
```

### Before re-rolling your app, test that the sidecars are still in place for existing pods

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*You will no longer see the mesh-inserted header: X-Mesh-Request-ID*

### Scale a service to show that new pods will not contain a sidecar after mesh removal

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*New ratings pods will not contain the sidecar*

### Remove or re-roll bookinfo to reset

```shell
$ for deps in $(kubectl get deployments --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' -n bookinfo); do kubectl rollout restart deployment/$deps -n bookinfo; done
$ kubectl get pods -n bookinfo
```

*You'll see the sidecar-attached pods terminating and new sidecar-less pods coming up.*

root@k8s1:/home/ubuntu/walkthrough# ll
total 28
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ./
drwxr-xr-x 8 ubuntu ubuntu  4096 Oct 13 20:28 ../
-rw-rw-r-- 1 ubuntu ubuntu 13762 Oct 13 20:09 NSM-Walkthrough-Lesson-1.md
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 build/
root@k8s1:/home/ubuntu/walkthrough# l
NSM-Walkthrough-Lesson-1.md  build/
root@k8s1:/home/ubuntu/walkthrough# l
NSM-Walkthrough-Lesson-1.md  build/
root@k8s1:/home/ubuntu/walkthrough# ll
total 28
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ./
drwxr-xr-x 8 ubuntu ubuntu  4096 Oct 13 20:28 ../
-rw-rw-r-- 1 ubuntu ubuntu 13762 Oct 13 20:09 NSM-Walkthrough-Lesson-1.md
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 build/
root@k8s1:/home/ubuntu/walkthrough# cd build/
root@k8s1:/home/ubuntu/walkthrough/build# ll
total 32
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 ./
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ../
-rw-rw-r-- 1 ubuntu ubuntu 13911 Oct 13 20:23 NSM-Walkthrough-Lesson-1.html
-rw-rw-r-- 1 ubuntu ubuntu    66 Oct 13 20:26 dockerfile
-rw-rw-r-- 1 ubuntu ubuntu   567 Oct 13 20:28 walkthrough.yaml
root@k8s1:/home/ubuntu/walkthrough/build# cat dockerfile 
FROM nginx:alpine
COPY ./*.html /usr/share/nginx/html/index.html

root@k8s1:/home/ubuntu/walkthrough/build# curl NSM^C
root@k8s1:/home/ubuntu/walkthrough/build# l
NSM-Walkthrough-Lesson-1.html  dockerfile  walkthrough.yaml
root@k8s1:/home/ubuntu/walkthrough/build# cat NSM-Walkthrough-Lesson-1.html 
<!DOCTYPE html>
<html>
<xmp theme="simplex" style="display:none;">
# NGINX Service Mesh: Lesson 1

## System setup

### Expose the following HTTPS ports in k8s1 via the deploy GUI. 
If you are using the official blueprint these have already been exposed, but if you
are building a new blueprint or deployment you will need to manually
expose the following:. 

- Prometheus: 9090
- Grafana: 3000
- Bookinfo Product Page: 9080
- Zipkin: 9411

### Familiarize yourself with a local registry:

*Local registry is `registry:5000`*. 

The below is a quick walkthrough on using the local registry.  It is not
required for NSM, simply some background on using a local registry with K8s
(which you will be using for your NSM deployment).

```shell
$ docker pull nginx
$ docker tag nginx:latest registry:5000/nginx:latest
$ docker push registry:5000/nginx:latest
$ wget https://raw.githubusercontent.com/kubernetes/website/master/content/en/examples/application/deployment.yaml
$ vim deployment.yaml
```

*Change image to `registry:5000/nginx:latest`*

```shell
$ kubectl apply -f ./deployment.yaml
$ kubectl get pods
$ kubectl describe pod/deployment-[GUID]
```

*Look for `Successfully pulled image "registry:5000..."` to make sure the local reg is working*

```shell
$ kubectl delete -f ./deployment.yaml
```

## Deploy NSM

### Set it up

```shell
$ export ver=0.6.0
$ gzip -dc nginx-meshctl_linux > nginx-meshctl && chmod 755 nginx-meshctl
$ tar zxvf nginx-mesh-images-0.6.0.tar.gz
```

### Load images into local repo:

```shell
$ docker load < nginx-mesh-images-$ver/nginx-mesh-api-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-metrics-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-sidecar-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-init-$ver.tar.gz
```

### Re-tag to load into registry:5000

```shell
$ docker tag nginx-mesh-sidecar:$ver registry:5000/nginx-mesh-sidecar:$ver && \
        docker tag nginx-mesh-init:$ver registry:5000/nginx-mesh-init:$ver && \
        docker tag nginx-mesh-metrics:$ver registry:5000/nginx-mesh-metrics:$ver && \
        docker tag nginx-mesh-api:$ver registry:5000/nginx-mesh-api:$ver
```

### Push newly tagged containers into registry:5000

```shell
$ docker push registry:5000/nginx-mesh-api:$ver && \
        docker push registry:5000/nginx-mesh-metrics:$ver && \
        docker push registry:5000/nginx-mesh-init:$ver && \
        docker push registry:5000/nginx-mesh-sidecar:$ver
```

### Verify all images are avail and ready for the mesh

```shell
$ docker image ls | grep "registry:5000/nginx-mesh"
```

## Deploy the mesh. 
*This walkthrough will disable auto-injection cluster-wide and enable the `bookinfo` namespace for auto-inect only. We will look at how to change this behavior after NSM is deployed later in the lesson.*

```shell
$ ./nginx-meshctl deploy \
        --disable-auto-inject \
        --enabled-namespaces bookinfo \
        --mtls-mode strict \
        --nginx-mesh-api-image "registry:5000/nginx-mesh-api:$ver" \
        --nginx-mesh-sidecar-image "registry:5000/nginx-mesh-sidecar:$ver" \
        --nginx-mesh-init-image "registry:5000/nginx-mesh-init:$ver" \
        --nginx-mesh-metrics-image "registry:5000/nginx-mesh-metrics:$ver"
```

### Check that auto-injection is disabled for the entire cluster by default but enabled for `bookinfo`

```shell
$ ./nginx-meshctl config | jq '.injection'

---
{
        "disabledNamespaces": [],
        "enabledNamespaces": [
                "bookinfo"
                ],
        "isAutoInjectEnabled": false
}
---
```

## Start Testing

### Deploy bookinfo first then inject and re-deploy

```shell
$ wget https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml
$ kubectl create namespace bookinfo
$ kubectl apply -f ./bookinfo.yaml -n bookinfo
$ kubectl get pods -n bookinfo
```

*Pod status should eventually show `Running` and `Ready` should show `2/2` for each pod*

### List containers in every pod in bookinfo to show that pods have been deployed w nginx-mesh sidecars

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*The above command will display a list of each container running in each pod
in namespace `bookinfo`.  You want to look for both the bookinfo application
container and the NSM sidecar container in each pod.  For example, you
should see something like `details-v1-74f858558f-69lll:
docker.io/istio/examples-bookinfo-details-v1:1.15.0,
registry:5000//nginx-mesh-sidecar:0.6.0,"*

### Demo enabled namespaces by deploying `bookinfo` in a namespace not on configured for NSM auto-injection

```shell
$ kubectl create namespace bookinfo-no-inject
$ kubectl apply -f ./bookinfo.yaml -n bookinfo-no-inject
$ kubectl get pods -n bookinfo-no-inject
```

*Pod status should eventually show `Running` and `Ready` should show `1/1` for each pod, showing that the mesh did not inject a sidecar into the same deployment*

### Create manual injection config and inject to namespace that's not enabled for auto-injection

```shell
$ kubectl create namespace bookinfo-man-inject
$ ./nginx-meshctl inject < bookinfo.yaml > bookinfo-man-inject.yaml
$ kubectl apply -f ./bookinfo-man-inject.yaml -n bookinfo-man-inject
$ kubectl get pods -n bookinfo-man-inject
```

*Pod status should eventually show Running and Ready should show `2/2` for each pod, showing that we created a manual injection app deployment and deployed that into a namespace that is not enabled for auto-injection but we still manage it from what we've added to the deployment.*

 ### Show injected sidecar container details

```shell
$ kubectl get pods -n bookinfo-man-inject -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl describe pod/$(kubectl get pod -l app=productpage -n bookinfo-man-inject -o jsonpath='{.items[0].metadata.name}') -n bookinfo-man-inject
```

*Similar to the above, the goal is to show that the NSM sidecar proxies have
been injected into the bookinfo app in a namespace that is not configured
for auto-inject.  This means that NSM is still managing traffic for the
bookinfo app in the unmanaged namespace `bookinfo-man-inject`.*

### Review manual injection details

```shell
$ diff bookinfo.yaml bookinfo-man-inject.yaml
```

*The diff will show that the new deployment, `bookinfo-man-inject.yaml`,
contains new specifications for injecting the NSM sidecar into each
application.  You are able to deploy this new NSM-managed application
deployment in any cluster where NSM is running, regardless of namespace.*

### List all services managed by the mesh

```shell
$ ./nginx-meshctl services
```

*Will return each service in the form of `namespace/service <ip_address> <port>`*

  
## Working with NSM, bookinfo, and scale examples 

### Simple connection to show sidecar is handling traffic

```shell
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*When NSM is configured with `mTLS strict`, the easiest way to test that
traffic flowing through each sidecar is to exec into one application
container, a `ratings` pod in this case, and connect to another app service
also managed by the mesh, `productpage`.  You will see the
`X-Mesh-Request-ID` header is appended by the egress sidecar, showing
traffic from ratings to productpage was managed by the mesh.*

### More manual way to test live traffic

```shell
$ kubectl port-forward -n bookinfo --address=0.0.0.0 svc/productpage 9080:9080&
```

- Call `https://<your_k8s_cli_image>:9080/productpage?u=normal` in your browser of choice

*NOTE: If you're using UDF and you've exposed port 9080 (which is exposed in
the default blueprint), you don't need to append the port to the URL, simply
use the exposed service URL from the UDF Access Methods GUI.*

*NOTE: Due to the way K8s handles port-forwards (which bypass init
iptables), you can't connect directly to productpages through the mesh
unless you're deploying N+ KIC.  Direct access should only be used to test
and to generate load (as traffic behind product pages will still be tagged
as mesh traffic for top, etc).  For more info on port-forward and iptables:
https://discuss.istio.io/t/how-does-kubectl-port-forward-bypass-envoy-mtls-enforcement/731/2*

### Generate traffic for later 

```shell
$ while true; do curl -I http://localhost:9080/productpage?u=normal; done
```

*From one of your UDF K8s nodes, the above command will generate simple GET
traffic into the mesh which will generate traffic flow through the various
microservice containers within bookinfo.*

### Show Grafana and Top

```shell
$ kubectl port-forward -n nginx-mesh --address=0.0.0.0 svc/grafana 3000:3000&
$ while true; do ./nginx-meshctl top pods -n bookinfo; sleep 1; done
```

- Call `https://<your_k8s_cli_image>:3000` to review the Grafana dashboard

*The first command will expose the Grafana service port so that it can be
access remotely via the previously exposed port in UDF Access Methods.  The
second command will loop the `nginx-meshctl top` command to show that NSM is
seeing and distributing the inter-service traffic between application pods.*

*NOTE: While it is possible to run both `while` traffic generators from the
same K8s instance by running each in the background (which can be managed
using standard *nix tools like `jobs` and/or `fg`), it is generally easier
to run the `nginx-meshctl top` loop from the node where you've installed NSM
and the traffic generator from another node.*

### Kill a pod to show the drop in Grafana and Top

```shell
$ kubectl delete pod/$(kubectl get pod -l app=reviews,version=v3 -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo
$ kubectl get pods -n bookinfo
```

*From another node in the cluster, delete the reviews pod so that K8s has to
re-generate the pod.  NSM will detect the re-gen and pick up traffic
management as soon as the pod becomes available.  Continue watching the
`nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods
become available.*

### Scale to show injection is constant

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*
  
### Scale back down

```shell
$ kubectl scale deployments ratings-v1 --replicas=1 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*

### To see/review NGINX config, exec into the sidecar

```shell
$ kubectl exec $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -c nginx-mesh-sidecar -n bookinfo -it -- cat /etc/nginx/nginx.conf
```
  
## Update NSM config and behavior

### Add two new namespaces: One with auto-inject enabled and one without (for testing manual injection), both used to test the mesh.

```shell
$ kubectl create namespace test-tools-injected
$ kubectl create namespace test-tools
```

### Query NSM API for autoinjection namespace data

```shell
$ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'
```

### Enable API and test by querying the auto-injection namespace allowlist

```shell
$ kubectl port-forward -n nginx-mesh svc/nginx-mesh-api 8443:443&
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

### Change auto-injection allowlist to include a new namespace via JSON payload to API

```shell
$ cat <<EOF > update-namespaces.json
{
        "op": "replace",
        "field": {
        "injection": {
                "isAutoInjectEnabled": false,
                "enabledNamespaces": ["bookinfo", "test-tools-injected"]
                }
        }
}
EOF

$ curl -vkX PATCH --header "Content-Type: application/json" https://localhost:8443/api/config -d @update-namespaces.json
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

*Or use CLI: $ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'*

## Remove NSM

*NOTE: Removing the mesh removes the control plane but not the data plane; sidecars stay in place but are reconfigured as transparent sidecars with no security or routing policies.*

### Remove NSM control plane

```shell
$ ./nginx-meshctl remove -y
```

### Before re-rolling your app, test that the sidecars are still in place for existing pods

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*You will no longer see the mesh-inserted header: X-Mesh-Request-ID*

### Scale a service to show that new pods will not contain a sidecar after mesh removal

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*New ratings pods will not contain the sidecar*

### Remove or re-roll bookinfo to reset

```shell
$ for deps in $(kubectl get deployments --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' -n bookinfo); do kubectl rollout restart deployment/$deps -n bookinfo; done
$ kubectl get pods -n bookinfo
```

*You'll see the sidecar-attached pods terminating and new sidecar-less pods coming up.*

</xmp>

<script src="http://strapdownjs.com/v/0.2/strapdown.js"></script>
</html>
root@k8s1:/home/ubuntu/walkthrough/build# 
root@k8s1:/home/ubuntu/walkthrough/build# l
NSM-Walkthrough-Lesson-1.html  dockerfile  walkthrough.yaml
root@k8s1:/home/ubuntu/walkthrough/build# ll
total 32
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 ./
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ../
-rw-rw-r-- 1 ubuntu ubuntu 13911 Oct 13 20:23 NSM-Walkthrough-Lesson-1.html
-rw-rw-r-- 1 ubuntu ubuntu    66 Oct 13 20:26 dockerfile
-rw-rw-r-- 1 ubuntu ubuntu   567 Oct 13 20:28 walkthrough.yaml
root@k8s1:/home/ubuntu/walkthrough/build# cat walkthrough.yaml 
apiVersion: apps/v1
kind: Deployment
metadata:
  name: walkthrough
spec:
  selector:
    matchLabels:
      run: walkthrough
  replicas: 2
  template:
    metadata:
      labels:
        run: walkthrough
    spec:
      containers:
      - name: walkthrough
        image: registry:5000/walkthrough:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: walkthrough-svc
  labels:
    run: walkthrough-svc
spec:
  type: NodePort
  ports:
  - port: 80
    protocol: TCP
    nodePort: 30007
  selector:
    run: walkthrough
root@k8s1:/home/ubuntu/walkthrough/build# kubectl -f apply 
NSM-Walkthrough-Lesson-1.html  dockerfile                     walkthrough.yaml               
root@k8s1:/home/ubuntu/walkthrough/build# kubectl -f apply 
NSM-Walkthrough-Lesson-1.html  dockerfile                     walkthrough.yaml               
root@k8s1:/home/ubuntu/walkthrough/build# kubectl -f apply walkthrough.yaml 
Error: unknown command "walkthrough.yaml" for "kubectl"
Run 'kubectl --help' for usage.
root@k8s1:/home/ubuntu/walkthrough/build# kubectl apply -f walkthrough.yaml 
The connection to the server localhost:8080 was refused - did you specify the right host or port?
root@k8s1:/home/ubuntu/walkthrough/build# ll
total 32
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 ./
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ../
-rw-rw-r-- 1 ubuntu ubuntu 13911 Oct 13 20:23 NSM-Walkthrough-Lesson-1.html
-rw-rw-r-- 1 ubuntu ubuntu    66 Oct 13 20:26 dockerfile
-rw-rw-r-- 1 ubuntu ubuntu   567 Oct 13 20:28 walkthrough.yaml
root@k8s1:/home/ubuntu/walkthrough/build# cd ..
root@k8s1:/home/ubuntu/walkthrough# ll
total 28
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ./
drwxr-xr-x 8 ubuntu ubuntu  4096 Oct 13 20:28 ../
-rw-rw-r-- 1 ubuntu ubuntu 13762 Oct 13 20:09 NSM-Walkthrough-Lesson-1.md
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 build/
root@k8s1:/home/ubuntu/walkthrough# cd ..
root@k8s1:/home/ubuntu# k
k: command not found
root@k8s1:/home/ubuntu# ll
total 63288
drwxr-xr-x 8 ubuntu ubuntu     4096 Oct 13 20:28 ./
drwxr-xr-x 3 root   root       4096 Sep  3 14:36 ../
-rw-rw-r-- 1 ubuntu ubuntu       19 Sep  4 12:03 .bash_aliases
-rw------- 1 ubuntu ubuntu       24 Oct  2 19:56 .bash_history
-rw-r--r-- 1 ubuntu ubuntu      220 Apr  4  2018 .bash_logout
-rw-r--r-- 1 ubuntu ubuntu     3771 Apr  4  2018 .bashrc
drwx------ 2 ubuntu ubuntu     4096 Sep  3 14:38 .cache/
drwx------ 2 ubuntu ubuntu     4096 Sep  4 13:29 .docker/
drwx------ 3 ubuntu ubuntu     4096 Sep  3 14:38 .gnupg/
-rw------- 1 ubuntu ubuntu      473 Oct  2 19:50 .joe_state
drwxr-xr-x 3 ubuntu ubuntu     4096 Sep  3 20:13 .kube/
-rw-r--r-- 1 ubuntu ubuntu      807 Apr  4  2018 .profile
drwx------ 2 ubuntu ubuntu     4096 Sep  3 14:48 .ssh/
-rw-r--r-- 1 ubuntu ubuntu        0 Sep  3 19:27 .sudo_as_admin_successful
-rw------- 1 ubuntu ubuntu    35995 Oct 13 20:28 .viminfo
-rw-r--r-- 1 ubuntu ubuntu 53635751 Oct  2 19:28 nginx-mesh-images-0.6.0.tar.gz
-rw-r--r-- 1 ubuntu ubuntu       65 Oct  2 19:28 nginx-mesh-images-0.6.0.tar.gz.md5
-rw-r--r-- 1 ubuntu ubuntu 11065927 Oct  2 19:29 nginx-meshctl_linux.gz
-rw-r--r-- 1 ubuntu ubuntu       57 Oct  2 19:30 nginx-meshctl_linux.gz.md5
drwxrwxr-x 3 ubuntu ubuntu     4096 Oct 13 20:20 walkthrough/
root@k8s1:/home/ubuntu# cd walkthrough/
root@k8s1:/home/ubuntu/walkthrough# l
NSM-Walkthrough-Lesson-1.md  build/
root@k8s1:/home/ubuntu/walkthrough# ll
total 28
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ./
drwxr-xr-x 8 ubuntu ubuntu  4096 Oct 13 20:28 ../
-rw-rw-r-- 1 ubuntu ubuntu 13762 Oct 13 20:09 NSM-Walkthrough-Lesson-1.md
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 build/
root@k8s1:/home/ubuntu/walkthrough# history 
    1  cd /sbin/
    2  ls
    3  exit
    4  cd /home/ubuntu/
    5  l
    6  ll
    7  cd walkthrough/
    8  ll
    9  cd build/
   10  ll
   11  docker ps
   12  cd ..
   13  l
   14  hsit
   15  history 
   16  ls -l
   17  l
   18  ll
   19  cat NSM-Walkthrough-Lesson-1.md 
   20  ll
   21  l
   22  ll
   23  cd build/
   24  ll
   25  cat dockerfile 
   26  l
   27  cat NSM-Walkthrough-Lesson-1.html 
   28  l
   29  ll
   30  cat walkthrough.yaml 
   31  kubectl -f apply walkthrough.yaml 
   32  kubectl apply -f walkthrough.yaml 
   33  ll
   34  cd ..
   35  ll
   36  cd ..
   37  k
   38  ll
   39  cd walkthrough/
   40  l
   41  ll
   42  history 
root@k8s1:/home/ubuntu/walkthrough# cd build/
root@k8s1:/home/ubuntu/walkthrough/build# ll
total 32
drwxrwxr-x 2 ubuntu ubuntu  4096 Oct 13 20:28 ./
drwxrwxr-x 3 ubuntu ubuntu  4096 Oct 13 20:20 ../
-rw-rw-r-- 1 ubuntu ubuntu 13911 Oct 13 20:23 NSM-Walkthrough-Lesson-1.html
-rw-rw-r-- 1 ubuntu ubuntu    66 Oct 13 20:26 dockerfile
-rw-rw-r-- 1 ubuntu ubuntu   567 Oct 13 20:28 walkthrough.yaml
root@k8s1:/home/ubuntu/walkthrough/build# cat NSM-Walkthrough-Lesson-1.html 
<!DOCTYPE html>
<html>
<xmp theme="simplex" style="display:none;">
# NGINX Service Mesh: Lesson 1

## System setup

### Expose the following HTTPS ports in k8s1 via the deploy GUI. 
If you are using the official blueprint these have already been exposed, but if you
are building a new blueprint or deployment you will need to manually
expose the following:. 

- Prometheus: 9090
- Grafana: 3000
- Bookinfo Product Page: 9080
- Zipkin: 9411

### Familiarize yourself with a local registry:

*Local registry is `registry:5000`*. 

The below is a quick walkthrough on using the local registry.  It is not
required for NSM, simply some background on using a local registry with K8s
(which you will be using for your NSM deployment).

```shell
$ docker pull nginx
$ docker tag nginx:latest registry:5000/nginx:latest
$ docker push registry:5000/nginx:latest
$ wget https://raw.githubusercontent.com/kubernetes/website/master/content/en/examples/application/deployment.yaml
$ vim deployment.yaml
```

*Change image to `registry:5000/nginx:latest`*

```shell
$ kubectl apply -f ./deployment.yaml
$ kubectl get pods
$ kubectl describe pod/deployment-[GUID]
```

*Look for `Successfully pulled image "registry:5000..."` to make sure the local reg is working*

```shell
$ kubectl delete -f ./deployment.yaml
```

## Deploy NSM

### Set it up

```shell
$ export ver=0.6.0
$ gzip -dc nginx-meshctl_linux > nginx-meshctl && chmod 755 nginx-meshctl
$ tar zxvf nginx-mesh-images-0.6.0.tar.gz
```

### Load images into local repo:

```shell
$ docker load < nginx-mesh-images-$ver/nginx-mesh-api-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-metrics-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-sidecar-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-init-$ver.tar.gz
```

### Re-tag to load into registry:5000

```shell
$ docker tag nginx-mesh-sidecar:$ver registry:5000/nginx-mesh-sidecar:$ver && \
        docker tag nginx-mesh-init:$ver registry:5000/nginx-mesh-init:$ver && \
        docker tag nginx-mesh-metrics:$ver registry:5000/nginx-mesh-metrics:$ver && \
        docker tag nginx-mesh-api:$ver registry:5000/nginx-mesh-api:$ver
```

### Push newly tagged containers into registry:5000

```shell
$ docker push registry:5000/nginx-mesh-api:$ver && \
        docker push registry:5000/nginx-mesh-metrics:$ver && \
        docker push registry:5000/nginx-mesh-init:$ver && \
        docker push registry:5000/nginx-mesh-sidecar:$ver
```

### Verify all images are avail and ready for the mesh

```shell
$ docker image ls | grep "registry:5000/nginx-mesh"
```

## Deploy the mesh. 
*This walkthrough will disable auto-injection cluster-wide and enable the `bookinfo` namespace for auto-inect only. We will look at how to change this behavior after NSM is deployed later in the lesson.*

```shell
$ ./nginx-meshctl deploy \
        --disable-auto-inject \
        --enabled-namespaces bookinfo \
        --mtls-mode strict \
        --nginx-mesh-api-image "registry:5000/nginx-mesh-api:$ver" \
        --nginx-mesh-sidecar-image "registry:5000/nginx-mesh-sidecar:$ver" \
        --nginx-mesh-init-image "registry:5000/nginx-mesh-init:$ver" \
        --nginx-mesh-metrics-image "registry:5000/nginx-mesh-metrics:$ver"
```

### Check that auto-injection is disabled for the entire cluster by default but enabled for `bookinfo`

```shell
$ ./nginx-meshctl config | jq '.injection'

---
{
        "disabledNamespaces": [],
        "enabledNamespaces": [
                "bookinfo"
                ],
        "isAutoInjectEnabled": false
}
---
```

## Start Testing

### Deploy bookinfo first then inject and re-deploy

```shell
$ wget https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml
$ kubectl create namespace bookinfo
$ kubectl apply -f ./bookinfo.yaml -n bookinfo
$ kubectl get pods -n bookinfo
```

*Pod status should eventually show `Running` and `Ready` should show `2/2` for each pod*

### List containers in every pod in bookinfo to show that pods have been deployed w nginx-mesh sidecars

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*The above command will display a list of each container running in each pod
in namespace `bookinfo`.  You want to look for both the bookinfo application
container and the NSM sidecar container in each pod.  For example, you
should see something like `details-v1-74f858558f-69lll:
docker.io/istio/examples-bookinfo-details-v1:1.15.0,
registry:5000//nginx-mesh-sidecar:0.6.0,"*

### Demo enabled namespaces by deploying `bookinfo` in a namespace not on configured for NSM auto-injection

```shell
$ kubectl create namespace bookinfo-no-inject
$ kubectl apply -f ./bookinfo.yaml -n bookinfo-no-inject
$ kubectl get pods -n bookinfo-no-inject
```

*Pod status should eventually show `Running` and `Ready` should show `1/1` for each pod, showing that the mesh did not inject a sidecar into the same deployment*

### Create manual injection config and inject to namespace that's not enabled for auto-injection

```shell
$ kubectl create namespace bookinfo-man-inject
$ ./nginx-meshctl inject < bookinfo.yaml > bookinfo-man-inject.yaml
$ kubectl apply -f ./bookinfo-man-inject.yaml -n bookinfo-man-inject
$ kubectl get pods -n bookinfo-man-inject
```

*Pod status should eventually show Running and Ready should show `2/2` for each pod, showing that we created a manual injection app deployment and deployed that into a namespace that is not enabled for auto-injection but we still manage it from what we've added to the deployment.*

 ### Show injected sidecar container details

```shell
$ kubectl get pods -n bookinfo-man-inject -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl describe pod/$(kubectl get pod -l app=productpage -n bookinfo-man-inject -o jsonpath='{.items[0].metadata.name}') -n bookinfo-man-inject
```

*Similar to the above, the goal is to show that the NSM sidecar proxies have
been injected into the bookinfo app in a namespace that is not configured
for auto-inject.  This means that NSM is still managing traffic for the
bookinfo app in the unmanaged namespace `bookinfo-man-inject`.*

### Review manual injection details

```shell
$ diff bookinfo.yaml bookinfo-man-inject.yaml
```

*The diff will show that the new deployment, `bookinfo-man-inject.yaml`,
contains new specifications for injecting the NSM sidecar into each
application.  You are able to deploy this new NSM-managed application
deployment in any cluster where NSM is running, regardless of namespace.*

### List all services managed by the mesh

```shell
$ ./nginx-meshctl services
```

*Will return each service in the form of `namespace/service <ip_address> <port>`*

  
## Working with NSM, bookinfo, and scale examples 

### Simple connection to show sidecar is handling traffic

```shell
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*When NSM is configured with `mTLS strict`, the easiest way to test that
traffic flowing through each sidecar is to exec into one application
container, a `ratings` pod in this case, and connect to another app service
also managed by the mesh, `productpage`.  You will see the
`X-Mesh-Request-ID` header is appended by the egress sidecar, showing
traffic from ratings to productpage was managed by the mesh.*

### More manual way to test live traffic

```shell
$ kubectl port-forward -n bookinfo --address=0.0.0.0 svc/productpage 9080:9080&
```

- Call `https://<your_k8s_cli_image>:9080/productpage?u=normal` in your browser of choice

*NOTE: If you're using UDF and you've exposed port 9080 (which is exposed in
the default blueprint), you don't need to append the port to the URL, simply
use the exposed service URL from the UDF Access Methods GUI.*

*NOTE: Due to the way K8s handles port-forwards (which bypass init
iptables), you can't connect directly to productpages through the mesh
unless you're deploying N+ KIC.  Direct access should only be used to test
and to generate load (as traffic behind product pages will still be tagged
as mesh traffic for top, etc).  For more info on port-forward and iptables:
https://discuss.istio.io/t/how-does-kubectl-port-forward-bypass-envoy-mtls-enforcement/731/2*

### Generate traffic for later 

```shell
$ while true; do curl -I http://localhost:9080/productpage?u=normal; done
```

*From one of your UDF K8s nodes, the above command will generate simple GET
traffic into the mesh which will generate traffic flow through the various
microservice containers within bookinfo.*

### Show Grafana and Top

```shell
$ kubectl port-forward -n nginx-mesh --address=0.0.0.0 svc/grafana 3000:3000&
$ while true; do ./nginx-meshctl top pods -n bookinfo; sleep 1; done
```

- Call `https://<your_k8s_cli_image>:3000` to review the Grafana dashboard

*The first command will expose the Grafana service port so that it can be
access remotely via the previously exposed port in UDF Access Methods.  The
second command will loop the `nginx-meshctl top` command to show that NSM is
seeing and distributing the inter-service traffic between application pods.*

*NOTE: While it is possible to run both `while` traffic generators from the
same K8s instance by running each in the background (which can be managed
using standard *nix tools like `jobs` and/or `fg`), it is generally easier
to run the `nginx-meshctl top` loop from the node where you've installed NSM
and the traffic generator from another node.*

### Kill a pod to show the drop in Grafana and Top

```shell
$ kubectl delete pod/$(kubectl get pod -l app=reviews,version=v3 -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo
$ kubectl get pods -n bookinfo
```

*From another node in the cluster, delete the reviews pod so that K8s has to
re-generate the pod.  NSM will detect the re-gen and pick up traffic
management as soon as the pod becomes available.  Continue watching the
`nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods
become available.*

### Scale to show injection is constant

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*
  
### Scale back down

```shell
$ kubectl scale deployments ratings-v1 --replicas=1 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*

### To see/review NGINX config, exec into the sidecar

```shell
$ kubectl exec $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -c nginx-mesh-sidecar -n bookinfo -it -- cat /etc/nginx/nginx.conf
```
  
## Update NSM config and behavior

### Add two new namespaces: One with auto-inject enabled and one without (for testing manual injection), both used to test the mesh.

```shell
$ kubectl create namespace test-tools-injected
$ kubectl create namespace test-tools
```

### Query NSM API for autoinjection namespace data

```shell
$ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'
```

### Enable API and test by querying the auto-injection namespace allowlist

```shell
$ kubectl port-forward -n nginx-mesh svc/nginx-mesh-api 8443:443&
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

### Change auto-injection allowlist to include a new namespace via JSON payload to API

```shell
$ cat <<EOF > update-namespaces.json
{
        "op": "replace",
        "field": {
        "injection": {
                "isAutoInjectEnabled": false,
                "enabledNamespaces": ["bookinfo", "test-tools-injected"]
                }
        }
}
EOF

$ curl -vkX PATCH --header "Content-Type: application/json" https://localhost:8443/api/config -d @update-namespaces.json
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

*Or use CLI: $ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'*

## Remove NSM

*NOTE: Removing the mesh removes the control plane but not the data plane; sidecars stay in place but are reconfigured as transparent sidecars with no security or routing policies.*

### Remove NSM control plane

```shell
$ ./nginx-meshctl remove -y
```

### Before re-rolling your app, test that the sidecars are still in place for existing pods

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*You will no longer see the mesh-inserted header: X-Mesh-Request-ID*

### Scale a service to show that new pods will not contain a sidecar after mesh removal

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*New ratings pods will not contain the sidecar*

### Remove or re-roll bookinfo to reset

```shell
$ for deps in $(kubectl get deployments --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' -n bookinfo); do kubectl rollout restart deployment/$deps -n bookinfo; done
$ kubectl get pods -n bookinfo
```

*You'll see the sidecar-attached pods terminating and new sidecar-less pods coming up.*

</xmp>

<script src="http://strapdownjs.com/v/0.2/strapdown.js"></script>
</html>
root@k8s1:/home/ubuntu/walkthrough/build# more NSM-Walkthrough-Lesson-1.html 
<!DOCTYPE html>
<html>
<xmp theme="simplex" style="display:none;">
# NGINX Service Mesh: Lesson 1

## System setup

### Expose the following HTTPS ports in k8s1 via the deploy GUI. 
If you are using the official blueprint these have already been exposed, but if you
are building a new blueprint or deployment you will need to manually
expose the following:. 

- Prometheus: 9090
- Grafana: 3000
- Bookinfo Product Page: 9080
- Zipkin: 9411

### Familiarize yourself with a local registry:

*Local registry is `registry:5000`*. 

The below is a quick walkthrough on using the local registry.  It is not
required for NSM, simply some background on using a local registry with K8s
(which you will be using for your NSM deployment).

```shell
$ docker pull nginx
$ docker tag nginx:latest registry:5000/nginx:latest
$ docker push registry:5000/nginx:latest
$ wget https://raw.githubusercontent.com/kubernetes/website/master/content/en/examples/application/deployment.yaml
$ vim deployment.yaml
```

*Change image to `registry:5000/nginx:latest`*

```shell
$ kubectl apply -f ./deployment.yaml
$ kubectl get pods
$ kubectl describe pod/deployment-[GUID]
```

*Look for `Successfully pulled image "registry:5000..."` to make sure the local reg is working*

```shell
$ kubectl delete -f ./deployment.yaml
```

## Deploy NSM

### Set it up

```shell
$ export ver=0.6.0
$ gzip -dc nginx-meshctl_linux > nginx-meshctl && chmod 755 nginx-meshctl
$ tar zxvf nginx-mesh-images-0.6.0.tar.gz
```

### Load images into local repo:

```shell
$ docker load < nginx-mesh-images-$ver/nginx-mesh-api-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-metrics-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-sidecar-$ver.tar.gz && \
        docker load < nginx-mesh-images-$ver/nginx-mesh-init-$ver.tar.gz
```

### Re-tag to load into registry:5000

```shell
$ docker tag nginx-mesh-sidecar:$ver registry:5000/nginx-mesh-sidecar:$ver && \
        docker tag nginx-mesh-init:$ver registry:5000/nginx-mesh-init:$ver && \
        docker tag nginx-mesh-metrics:$ver registry:5000/nginx-mesh-metrics:$ver && \
        docker tag nginx-mesh-api:$ver registry:5000/nginx-mesh-api:$ver
```

### Push newly tagged containers into registry:5000

```shell
$ docker push registry:5000/nginx-mesh-api:$ver && \
        docker push registry:5000/nginx-mesh-metrics:$ver && \
        docker push registry:5000/nginx-mesh-init:$ver && \
        docker push registry:5000/nginx-mesh-sidecar:$ver
```

### Verify all images are avail and ready for the mesh

```shell
$ docker image ls | grep "registry:5000/nginx-mesh"
```

## Deploy the mesh. 
*This walkthrough will disable auto-injection cluster-wide and enable the `bookinfo` namespace for auto-inect only. We will look at how to change this behavior after NSM is deployed later in the lesson.*

```shell
$ ./nginx-meshctl deploy \
        --disable-auto-inject \
        --enabled-namespaces bookinfo \
        --mtls-mode strict \
        --nginx-mesh-api-image "registry:5000/nginx-mesh-api:$ver" \
        --nginx-mesh-sidecar-image "registry:5000/nginx-mesh-sidecar:$ver" \
        --nginx-mesh-init-image "registry:5000/nginx-mesh-init:$ver" \
        --nginx-mesh-metrics-image "registry:5000/nginx-mesh-metrics:$ver"
```

### Check that auto-injection is disabled for the entire cluster by default but enabled for `bookinfo`

```shell
$ ./nginx-meshctl config | jq '.injection'

---
{
        "disabledNamespaces": [],
        "enabledNamespaces": [
                "bookinfo"
                ],
        "isAutoInjectEnabled": false
}
---
```

## Start Testing

### Deploy bookinfo first then inject and re-deploy

```shell
$ wget https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml
$ kubectl create namespace bookinfo
$ kubectl apply -f ./bookinfo.yaml -n bookinfo
$ kubectl get pods -n bookinfo
```

*Pod status should eventually show `Running` and `Ready` should show `2/2` for each pod*

### List containers in every pod in bookinfo to show that pods have been deployed w nginx-mesh sidecars

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*The above command will display a list of each container running in each pod
in namespace `bookinfo`.  You want to look for both the bookinfo application
container and the NSM sidecar container in each pod.  For example, you
should see something like `details-v1-74f858558f-69lll:
docker.io/istio/examples-bookinfo-details-v1:1.15.0,
registry:5000//nginx-mesh-sidecar:0.6.0,"*

### Demo enabled namespaces by deploying `bookinfo` in a namespace not on configured for NSM auto-injection

```shell
$ kubectl create namespace bookinfo-no-inject
$ kubectl apply -f ./bookinfo.yaml -n bookinfo-no-inject
$ kubectl get pods -n bookinfo-no-inject
```

*Pod status should eventually show `Running` and `Ready` should show `1/1` for each pod, showing that the mesh did not inject a sidecar into the same deployment*

### Create manual injection config and inject to namespace that's not enabled for auto-injection

```shell
$ kubectl create namespace bookinfo-man-inject
$ ./nginx-meshctl inject < bookinfo.yaml > bookinfo-man-inject.yaml
$ kubectl apply -f ./bookinfo-man-inject.yaml -n bookinfo-man-inject
$ kubectl get pods -n bookinfo-man-inject
```

*Pod status should eventually show Running and Ready should show `2/2` for each pod, showing that we created a manual injection app deployment and deployed that into a namespace that is not enabled for auto-injection but we still manage it from what we've added to the deployment.*

 ### Show injected sidecar container details

```shell
$ kubectl get pods -n bookinfo-man-inject -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl describe pod/$(kubectl get pod -l app=productpage -n bookinfo-man-inject -o jsonpath='{.items[0].metadata.name}') -n bookinfo-man-inject
```

*Similar to the above, the goal is to show that the NSM sidecar proxies have
been injected into the bookinfo app in a namespace that is not configured
for auto-inject.  This means that NSM is still managing traffic for the
bookinfo app in the unmanaged namespace `bookinfo-man-inject`.*

### Review manual injection details

```shell
$ diff bookinfo.yaml bookinfo-man-inject.yaml
```

*The diff will show that the new deployment, `bookinfo-man-inject.yaml`,
contains new specifications for injecting the NSM sidecar into each
application.  You are able to deploy this new NSM-managed application
deployment in any cluster where NSM is running, regardless of namespace.*

### List all services managed by the mesh

```shell
$ ./nginx-meshctl services
```

*Will return each service in the form of `namespace/service <ip_address> <port>`*

  
## Working with NSM, bookinfo, and scale examples 

### Simple connection to show sidecar is handling traffic

```shell
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*When NSM is configured with `mTLS strict`, the easiest way to test that
traffic flowing through each sidecar is to exec into one application
container, a `ratings` pod in this case, and connect to another app service
also managed by the mesh, `productpage`.  You will see the
`X-Mesh-Request-ID` header is appended by the egress sidecar, showing
traffic from ratings to productpage was managed by the mesh.*

### More manual way to test live traffic

```shell
$ kubectl port-forward -n bookinfo --address=0.0.0.0 svc/productpage 9080:9080&
```

- Call `https://<your_k8s_cli_image>:9080/productpage?u=normal` in your browser of choice

*NOTE: If you're using UDF and you've exposed port 9080 (which is exposed in
the default blueprint), you don't need to append the port to the URL, simply
use the exposed service URL from the UDF Access Methods GUI.*

*NOTE: Due to the way K8s handles port-forwards (which bypass init
iptables), you can't connect directly to productpages through the mesh
unless you're deploying N+ KIC.  Direct access should only be used to test
and to generate load (as traffic behind product pages will still be tagged
as mesh traffic for top, etc).  For more info on port-forward and iptables:
https://discuss.istio.io/t/how-does-kubectl-port-forward-bypass-envoy-mtls-enforcement/731/2*

### Generate traffic for later 

```shell
$ while true; do curl -I http://localhost:9080/productpage?u=normal; done
```

*From one of your UDF K8s nodes, the above command will generate simple GET
traffic into the mesh which will generate traffic flow through the various
microservice containers within bookinfo.*

### Show Grafana and Top

```shell
$ kubectl port-forward -n nginx-mesh --address=0.0.0.0 svc/grafana 3000:3000&
$ while true; do ./nginx-meshctl top pods -n bookinfo; sleep 1; done
```

- Call `https://<your_k8s_cli_image>:3000` to review the Grafana dashboard

*The first command will expose the Grafana service port so that it can be
access remotely via the previously exposed port in UDF Access Methods.  The
second command will loop the `nginx-meshctl top` command to show that NSM is
seeing and distributing the inter-service traffic between application pods.*

*NOTE: While it is possible to run both `while` traffic generators from the
same K8s instance by running each in the background (which can be managed
using standard *nix tools like `jobs` and/or `fg`), it is generally easier
to run the `nginx-meshctl top` loop from the node where you've installed NSM
and the traffic generator from another node.*

### Kill a pod to show the drop in Grafana and Top

```shell
$ kubectl delete pod/$(kubectl get pod -l app=reviews,version=v3 -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo
$ kubectl get pods -n bookinfo
```

*From another node in the cluster, delete the reviews pod so that K8s has to
re-generate the pod.  NSM will detect the re-gen and pick up traffic
management as soon as the pod becomes available.  Continue watching the
`nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods
become available.*

### Scale to show injection is constant

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*
  
### Scale back down

```shell
$ kubectl scale deployments ratings-v1 --replicas=1 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*

### To see/review NGINX config, exec into the sidecar

```shell
$ kubectl exec $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -c nginx-mesh-sidecar -n bookinfo -it -- cat /etc/nginx/nginx.conf
```
  
## Update NSM config and behavior

### Add two new namespaces: One with auto-inject enabled and one without (for testing manual injection), both used to test the mesh.

```shell
$ kubectl create namespace test-tools-injected
$ kubectl create namespace test-tools
```

### Query NSM API for autoinjection namespace data

```shell
$ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'
```

### Enable API and test by querying the auto-injection namespace allowlist

```shell
$ kubectl port-forward -n nginx-mesh svc/nginx-mesh-api 8443:443&
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

### Change auto-injection allowlist to include a new namespace via JSON payload to API

```shell
$ cat <<EOF > update-namespaces.json
{
        "op": "replace",
        "field": {
        "injection": {
                "isAutoInjectEnabled": false,
                "enabledNamespaces": ["bookinfo", "test-tools-injected"]
                }
        }
}
EOF

$ curl -vkX PATCH --header "Content-Type: application/json" https://localhost:8443/api/config -d @update-namespaces.json
$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'
```

*Or use CLI: $ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'*

## Remove NSM

*NOTE: Removing the mesh removes the control plane but not the data plane; sidecars stay in place but are reconfigured as transparent sidecars with no security or routing policies.*

### Remove NSM control plane

```shell
$ ./nginx-meshctl remove -y
```

### Before re-rolling your app, test that the sidecars are still in place for existing pods

```shell
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage
```

*You will no longer see the mesh-inserted header: X-Mesh-Request-ID*

### Scale a service to show that new pods will not contain a sidecar after mesh removal

```shell
$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
```

*New ratings pods will not contain the sidecar*

### Remove or re-roll bookinfo to reset

```shell
$ for deps in $(kubectl get deployments --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' -n bookinfo); do kubectl rollout restart deployment/$deps -n bookinfo; done
$ kubectl get pods -n bookinfo
```

*You'll see the sidecar-attached pods terminating and new sidecar-less pods coming up.*

</xmp>

<script src="http://strapdownjs.com/v/0.2/strapdown.js"></script>
</html>
