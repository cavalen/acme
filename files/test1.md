<!DOCTYPE html>
<html>
<xmp theme="simplex" style="display:none;">
# NGINX Service Mesh: Lesson 1

## System setup

### Expose the following HTTPS ports in k8s1 via the deploy GUI. 
*If you are using the official blueprint these have already been exposed, but if you are building a new blueprint or deployment you will need to manually expose the following*

- Prometheus: 9090
- Grafana: 3000
- Zipkin: 9411

### To test/familiarize yourself with a local registry:

While NGINX Service Mesh supports pulling the control and data plane images directly from F5's container registry during install, it's helpful to know how to configure NSM to pull images from your own reposititory (helpful in an air-gapped environment). The below section will help familiarize you with manually pulling/tagging/pushing images to the local registry in UDF. This process is more typically done when pushing images to a cloud container registry such as ECR, GCR, Azure storage blob, etc. 

*Local registry is `registry:5000`*. 

The below is a quick walkthrough on using the local registry. It is not required for NSM, simply some background on using a local registry with K8s (which you will be using for your NSM deployment).

	$ docker pull nginx
	$ docker tag nginx:latest registry:5000/nginx:latest
	$ docker push registry:5000/nginx:latest
	$ wget https://raw.githubusercontent.com/kubernetes/website/master/content/en/examples/application/deployment.yaml
	$ vim deployment.yaml
	
*Change image to `registry:5000/nginx:latest`*
		
	$ kubectl apply -f ./deployment.yaml
	$ kubectl get pods
	$ kubectl describe pod/deplomyment-[GUID]
	
*Look for `Successfully pulled image "registry:5000..."` to make sure the local reg is working*

	$ kubectl delete -f ./deployment.yaml
	
## Deploy NSM

### Set it up
*The install method outlined here pulls NSM images directly from docker-registry.nginx.com/nsm. For additional options, including manually downloading the images, tagging them, and pushing them into a private registry for air-gap installation (either registry:5000 locally or to a cloud-based container registry such as gcr) please see https://docs.nginx.com for full NSM installation details. 

### Download `nginx-meshctl_linux.gz` from either downloads.f5.com or MyF5

	$ export ver=<CURRENT NSM VERSION>
	$ gzip -dc nginx-meshctl_linux.gz > nginx-meshctl && chmod 755 nginx-meshctl

## Deploy the mesh. 
*This walkthrough will disable auto-injection cluster-wide and enable the `bookinfo` namespace for auto-inect only. We will look at how to change this behavior after NSM is deployed later in the lesson.*

### Pull from F5's public container registry*

	$ ./nginx-meshctl deploy \
	  --disable-auto-inject \
	  --enabled-namespaces bookinfo \
	  --mtls-mode strict \
	  --mtls-trust-domain nginx.mesh \
	  --registry-server docker-registry.nginx.com/nsm \
	  --image-tag $ver

### Check that install was successful and auto-injection is disabled for the entire cluster by default but enabled for `bookinfo`

	$ ./nginx-meshctl version

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

*With the `./nginx-meshctl version` command, you won't see a version string for the sidecar versions until you deploy an app that is managed by NSM. After deploying the app you will see a new version string returned for each sidecar version managed by NSM.*

## Start Testing

  
### Deploy bookinfo first then inject and re-deploy

	$ wget https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml
	$ kubectl create namespace bookinfo
	$ kubectl apply -f ./bookinfo.yaml -n bookinfo
	$ kubectl get pods -n bookinfo

*Pod status should eventually show `Running` and `Ready` should show `2/2` for each pod*

### List containers in every pod in bookinfo to show that pods have been deployed w nginx-mesh sidecars

	$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort

*The above command will display a list of each container running in each pod in namespace `bookinfo`.  You want to look for both the bookinfo application container and the NSM sidecar container in each pod.  For example, you should see something like `details-v1-74f858558f-69lll: docker.io/istio/examples-bookinfo-details-v1:1.15.0, registry:5000//nginx-mesh-sidecar:1.1.0"*

### Demo enabled namespaces by deploying `bookinfo` in a namespace not on configured for NSM auto-injection

	$ kubectl create namespace bookinfo-no-inject
	$ kubectl apply -f ./bookinfo.yaml -n bookinfo-no-inject
	$ kubectl get pods -n bookinfo-no-inject

*Pod status should eventually show `Running` and `Ready` should show `1/1` for each pod, showing that the mesh did not inject a sidecar into the same deployment*

### Create manual injection config and inject to namespace that's not enabled for auto-injection

	$ kubectl create namespace bookinfo-man-inject
	$ ./nginx-meshctl inject < bookinfo.yaml > bookinfo-man-inject.yaml
	$ kubectl apply -f ./bookinfo-man-inject.yaml -n bookinfo-man-inject
	$ kubectl get pods -n bookinfo-man-inject

*Pod status should eventually show Running and Ready should show `2/2` for each pod, showing that we created a manual injection app deployment and deployed that into a namespace that is not enabled for auto-injection but we still manage it from what we've added to the deployment.*

 ### Show injected sidecar container details

	$ kubectl get pods -n bookinfo-man-inject -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
	$ kubectl describe pod/$(kubectl get pod -l app=productpage -n bookinfo-man-inject -o jsonpath='{.items[0].metadata.name}') -n bookinfo-man-inject

*Similar to the above, the goal is to show that the NSM sidecar proxies have been injected into the bookinfo app in a namespace that is not configured for auto-inject.  This means that NSM is still managing traffic for the bookinfo app in the unmanaged namespace `bookinfo-man-inject`.*

### Review manual injection details

	$ diff bookinfo.yaml bookinfo-man-inject.yaml

*The diff will show that the new deployment, `bookinfo-man-inject.yaml`, contains new specifications for injecting the NSM sidecar into each application.  You are able to deploy this new NSM-managed application deployment in any cluster where NSM is running, regardless of namespace.*

### List all services managed by the mesh

	$ ./nginx-meshctl services

*Will return each service in the form of `namespace/service <ip_address> <port>`*

  
## Working with NSM, bookinfo, and scale examples 

### Simple connection to show sidecar is handling traffic

	$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage

*When NSM is configured with `mTLS strict`, the easist way to test that traffic flowing through each sidecar is to exec into one application container, a `ratings` pod in this case, and connect to another app service also managed by the mesh, `productpage`.  You will see the `X-Mesh-Request-ID` header is appended by the ingress sidecar, showing traffic from ratings to productpage was managed by the mesh.*

*NOTE: When in mTLS strict mode, you can't connect directly to productpages through the mesh unless you're deploying N+ KIC. For more information on configuring NGINX Plus KIC for ingress into NSM, please see https://docs.nginx.com/nginx-service-mesh/tutorials/kic/deploy-with-kic/*

### Generate traffic for demos

	 $ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- bash -c 'while true; do curl -I productpage:9080/productpage?u=normal; done'

*From one of your UDF K8s nodes, the above command will exec into a container and generate simple GET traffic into the mesh which will start traffic flowing through the various microservice containers within bookinfo and be available to your visualization tools like Grafana.*

### Show Grafana and Top

*NSM ships with a default Grafana dashboard that's used when NSM installs Grafana as part of the control plane. If you are running a dedicated Grafana instance, example dashboards can be found at https://github.com/nginxinc/nginx-service-mesh/tree/main/examples/grafana*

	$ kubectl port-forward -n nginx-mesh --address=0.0.0.0 svc/grafana 3000:3000&
	$ while true; do ./nginx-meshctl top pods -n bookinfo; sleep 1; done

- Call `https://<your_k8s_cli_image>:3000` to review the Grafana dashboard

*The first command will expose the Grafana service port so that it can be access remotely via the previously exposed port in UDF Access Methods. The second command will loop the `nginx-meshctl top` command to show that NSM is seeing and distributing the inter-service traffic between application pods.*

*NOTE: While it is possible to run both `while` traffic generators from the same K8s instance by running each in the background (which can be managed using standard *nix tools like `jobs` and/or `fg`), it is generally easier to run the `nginx-meshctl top` loop from the node where you've installed NSM and the traffic generator from another node.*

### Kill a pod to show the drop in Grafana and Top

	$ kubectl delete pod/$(kubectl get pod -l app=reviews,version=v3 -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo
	$ kubectl get pods -n bookinfo

*From another node in the cluster, delete the reviews pod so that K8s has to re-generate the pod.  NSM will detect the re-gen and pick up traffic management as soon as the pod becomes available. Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available.*

### Scale to show injection is constant

	$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
	$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
	
*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*
  
### Scale back down

	$ kubectl scale deployments ratings-v1 --replicas=1 -n bookinfo
	$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort

*Continue watching the `nginx-meshctl top` loop and Grafana to see NSM redistribute traffic as pods become available*

### To see/review NGINX config, exec into the sidecar

	$ kubectl exec $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -c nginx-mesh-sidecar -n bookinfo -it -- cat /etc/nginx/nginx.conf

  
## Update NSM config and behavior

### Add two new namespaces: One with auto-inject enabled and one without (for testing manual injection), both used to test the mesh.

	$ kubectl create namespace test-tools-injected
	$ kubectl create namespace test-tools

### Query NSM API for autoinjection namespace data (which should only be bookinfo at this stage)

	$ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'

### Enable API and test by querying the auto-injection namespace allowlist (same result, different method to retrieve/verify)

	$ kubectl port-forward -n nginx-mesh svc/nginx-mesh-api 8443:443&
	$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'

### Change auto-injection allowlist to include a new namespace via JSON payload to API

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

	$ curl -kX PATCH --header "Content-Type: application/json" https://localhost:8443/api/config -d @update-namespaces.json
	$ curl -ks https://localhost:8443/api/config | jq '.injection.enabledNamespaces[]'

*Or use CLI: $ ./nginx-meshctl config | jq '.injection.enabledNamespaces[]'*

## Remove NSM

*NOTE: Removing the mesh removes the control plane but not the data plane; sidecars stay in place but are reconfigured as transparent sidecars with no security or routing policies.*

### Remove NSM control plane

	$ ./nginx-meshctl remove -y

### Before re-rolling your app, test that the sidecars are still in place for existing pods

	$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort
	$ kubectl exec -it $(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}') -n bookinfo -c ratings -- curl -I productpage:9080/productpage

*You will no longer see the mesh-inserted header: X-Mesh-Request-ID*

### Scale a service to show that new pods will not contain a sidecar after mesh removal

	$ kubectl scale deployments ratings-v1 --replicas=3 -n bookinfo
	$ kubectl get pods -n bookinfo -o=jsonpath='{range .items[*]}{"\n"}{.metadata.name}{":\t"}{range .spec.containers[*]}{.image}{", "}{end}{end}' | sort

*New ratings pods will not contain the sidecar*

### Remove or re-roll bookinfo to reset

	$ for deps in $(kubectl get deployments --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' -n bookinfo); do kubectl rollout restart deployment/$deps -n bookinfo; done
	$ kubectl get pods -n bookinfo

*You'll see the sidecar-attached pods terminating and new sidecar-less pods coming up.*

</xmp>

<script src="http://strapdownjs.com/v/0.2/strapdown.js"></script>
</html>

