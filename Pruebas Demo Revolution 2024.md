# Pruebas Lab Openshift - Revolution 2024

### NOTA: Antes de comenzar desactivar ACL de los VS:
- ### Dashboard (nginx-ingress)(dashboard-vs.yaml)
- ### Keycloak (oidc)(virtual-server-idp.yaml)
- ### Brewz (5-virtualserver-brewz.yaml)(/)(/api)

## *Escenario 1: Despliegue de Brewz:*
##### Despligue del VirtualServer BREWZ con Active Healthchecks y Backup Service, en **https://brewz.cvlab.me**
- Crear el VirtualServer:
    ```sh
    kubectl apply -f 1-virtualserver-brewz.yaml
    kubectl get vs -n brewz
    ```
- Explicar Manifiesto (Active Health Checks y Backup Service)
- Abrir el dashboard de Nginx Ingress y ver los healthchecks y upstreams: **https://dashboard.cvlab.me**
- Mostra la app en **https://brewz.cvlab.me**. Mostrar que no esta protegida (seguridad va mas adelante)
- Mostrar el primer item, que tiene un numero de Tarjeta de Credito (no se hace nada de Security en Escenario #1)
- Explicar como OpenShift no tiene visibilidad avanzada de los PODs de K8S, vemos como funcionan los HealthCheck activos mostrando el manifiesto `1-virtualserver-brewz.yaml`
- Abrir la consola de Openshift: **https://console-openshift-console.apps.jp0tvppu.eastus2.aroapp.io/**
    | Username | Password             |
    |----------|----------------------|
    | kubeadmin   | 6KK5V-IEni7-VHo8d-eLRvV |
- Mostrar la configuracion de Routes (Network > Routes > NS Brewz)
- Abrir Route: **http://route-brewz-brewz.apps.jp0tvppu.eastus2.aroapp.io**
- Simular fallo al pod de SPA: 
  - Shell al Pod:
    ```sh
    POD=$(kubectl get pod -n brewz -o custom-columns=:.metadata.name | grep spa | head -1); echo $POD
    kubectl exec -it -n brewz $POD -- sh
    ```
  - Editar el Web Server:
     ```sh
    cat <<EOF > /tmp/index.html
    <html>
      <body>
        <center>
          <h1> BREWZ is not feeling well ...</h1><p>
          <img src=https://raw.githubusercontent.com/cavalen/acme/master/beer-broken.jpg>
        </center>
      </body>
    </html>
    EOF
    ```
  - Aplicar cambios y reiniciar nginx:
    ```sh
    sed -i 's/\/usr\/share\/nginx\/html;/\/tmp;/g' /etc/nginx/nginx.conf
    nginx -s reload
    exit
    ```
  - Mostrar de nuevo el Dashboard de NGINX. con el monitor y el servicio
  - Refresh al router, debe mostrar un servicio no funcional (aunque con HTTP/200 OK)
  - Al refrescar el servicio via el Ingress (https://brewz.cvlab.me) se debe mostrar el servicio de Backup (spa-dark)
  - Explicar _Service Insight_ y hacer un curl al servicio
    -  `curl -k http://ingress.cvlab.me:9114/probe/brewz.cvlab.me`
  - Matar el pod con problemas:
    - `kubectl delete pod -n brewz $POD`
---

## *Escenario 2: Ruteo Avanzado (ej: A/B, Blue/Green):*
##### Adicion de Split/Match para ruteo a mmutiples servicios basados en una condicion
- Mostar manifiesto, se incluye la directiva `matches` que rutea a un servicio alterno dependiendo de una condicion, en este caso una cookie llamada `app_version` con valor `dark`
- Aplicar Manifiesto #2
    ```sh
    kubectl apply -f 2-virtualserver-brewz.yaml
    ```
- En el browser ir a **https://brewz.cvlab.me**, adicionar una cookie, se debe mostrar **_spa-dark_**
    | Header   | Value              |
    |----------|------------------|
    | Cookie   | app_version=dark |  

--- 

## *Escenario 3: WAF para SPA:*
##### Despligue de politicas de WAF y comparacion vs Openshift Router
- Mostar manifiesto del VirtualServer `3-virtualserver-brewz.yaml` , se aplica la directiva `policies :` en `/` y `/api`
- Mostrar Policy `waf-policy-spa.yaml`
- Mostrar AppPolicy `waf-ap-policy-spa.yaml`
- Validar que la app es vulnerable: **https://brewz.cvlab.me**
  - Hacer un XSS, por ejemplo `/<script>Attack</script>`
  - No hay bloqueo de Informacion Sensible/Dataguard (Descripcion del Item #1 del catalogo)
- Aplicar Manifiesto #3
    ```sh
    kubectl apply -f 3-virtualserver-brewz.yaml
    ```
- Validar:
  - Custom Response Page (con un XSS), referenciada de forma remota en Github
  - Bloqueo de Informacion Sensible/Dataguard (Descripcion del Item #1 del catalogo)
  - Custom Signatures (Mostrar Manifiesto y agregar un Header llamado 'test: hackerz')
  - Volver al Router de Openshift **http://route-brewz-brewz.apps.jp0tvppu.eastus2.aroapp.io** --> No tiene seguridad

---

## *Escenario 4.1: API Security - Parte 1*
##### API Security con WAF y validacion de swagger file, JSON blocking message
- Mostar manifiesto del VirtualServer `4.1-virtualserver-brewz.yaml`, se cambia el policy `waf-policy-spa` del path `/api` por `waf-policy-api` que esta optimizada para proteger llamadas a un API en lugar de un Frontend
- Aplicar Manifiesto #4.1
    ```sh
    kubectl apply -f 4.1-virtualserver-brewz.yaml
    ```
- Abrir Postman, Coleccion **_Brewz - SPA_** y probar todos los requests.
  - Step 1.1 GET Products : **OK**
  - Step 1.2 GET Inventory : **OK**
  - Step 2.1 GET product 123 : **OK + Dataguard**
  - Step 2.2 GET Invalid Product : **OK, Respuesta valida (404), pero NO es JSON**
  - Step 3.1 GET Cart for valid user : **OK + Dataguard**
  - Step 3.2 GET cart for invalid user : **Violation + Blocking page JSON, tomar nota del Support_ID**
  - Step 4.1. POST cart item for user 12345 - unexpectedProperty : **Violation + Blocking page JSON, tomar nota del Support_ID**
  - Step 4.2.1 POST cart item for user 12345 - invalid content (NoSQL Inj) : **Violation + Blocking page JSON, tomar nota del Support_ID**
  - Step 4.2.2 POST cart item for user 12345 - invalid content (NoSQL Inj 2) : **No hacer, igual al anterior**
  - Step 4.3. POST cart item for user 12345 - valid content : **OK**
- Mostrar los Dashboards de Grafana, el general y luego los support ID de los Step 3.2, 4.1, 4.2.1 - **http://grafana.cvlab.me:3000**
 
---

## *Escenario 4.2: API Security - Parte 2*
##### Modificar respuestas 404 TXT a JSON del API
- Usando el modelo de Circuit Breaker, interceptar errores 404 y modificarlos
- Mostar manifiesto del VirtualServer `4.2-virtualserver-brewz.yaml`, seccion `errorPages` 
- Aplicar Manifiesto #4.2
    ```sh
    kubectl apply -f 4.2-virtualserver-brewz.yaml
    ```
- Probar desde Postman, `Step 2.2 GET Invalid Product`
---

## *Escenario 4.3: API Security - Parte 3*
##### API Security, adicionar JWT Auth 
- Mostar manifiesto del VirtualServer `4.3-virtualserver-brewz.yaml`, seccion `policies:` del path `/api/recommendations` y `errorPages` para respuestas 401 Not Authorized de TXT a JSON
- Mostrar manifiesto de Policy JWT, `jwt-policy.yaml`
- Probar desde Postaman `Step 5. GET recommendations`, el API funciona y no pide autenticacion.
- Aplicar Manifiesto #4.3 
    ```sh
    kubectl apply -f 4.3-virtualserver-brewz.yaml
    ```
- Probar desde Postman `Step 5. GET recommendations`, respuesta 401 JSON - `Authorization Required`
- Editar el request de Postman, adicionar un header nuevo:
    | Header   | Value            |
    |----------|------------------|
    | token    | eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjAwMDEifQ.eyJuYW1lIjoiUXVvdGF0aW9uIFN5c3RlbSIsInN1YiI6InF1b3RlcyIsImlzcyI6Ik15IEFQSSBHYXRld2F5In0.ggVOHYnVFB8GVPE-VOIo3jD71gTkLffAY0hQOGXPL2I |  
---

## *Escenario 4.4: API Security - Parte 4*
##### API Security, adicionar Rate Limiting
- Mostar manifiesto del VirtualServer `4.4-virtualserver-brewz.yaml`, seccion `policies:` del path `/api/recommendations`  y `errorPages` para respuestas 429 Not Authorized de TXT a JSON
- Mostrar manifiesto de Policy Rate Limit, `rate-limit.yaml`
- Probar desde Postaman `Step 5. GET recommendations`, el API aun tiene autenticacion.
- Aplicar Manifiesto #4.4
    ```sh
    kubectl apply -f 4.4-virtualserver-brewz.yaml
    ```
- Probar desde CLI, y validar la respuesta `429 Too Many Requests`
    ```sh
    while true; do curl -k -X GET -H "token: `cat token-good.jwt`" https://brewz.cvlab.me/api/recommendations; sleep 0.5; echo "\n------------------\n"; done;
    ```

---

## *Escenario 5: OIDC y Cross-Namespace deployment*
##### OIDC al path /supersecret, que lleva a un servicio en el namespace supersecret en K8S
- Mostrar manifiesto del VirtualServer `5-virtualserver-brewz.yaml`
- Mostrar manifiesto de OIDC `oidc-brewz.yaml`
- Mostrar manifiesto de VirtualServerRoute `vsroute-supersecret.yaml`
- Mostrar Namespaces y Servicios
   ```sh
   kubectl get virtualserverroutes -n supersecret
   kubectl get svc -n supersecret
   ```
- Ir a **https://keycloak.cvlab.me** y crear un usuario nuevo (ej revo)
- Consultar Brewz - **https://brewz.cvlab.me/supersecret**
