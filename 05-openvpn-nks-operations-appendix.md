# 05. NKS OpenVPN 운영 부록

- 이 문서는 [01-openvpn-nks-build-guide.md](./01-openvpn-nks-build-guide.md)의 운영 부록이다.
- 기존 가이드의 `## 10. 인증서 갱신 / 폐기 / 교체`부터 `## 11. 운영 자동화 권장`까지를 분리했다.
- 트러블슈팅은 [06-openvpn-nks-troubleshooting-guide.md](./06-openvpn-nks-troubleshooting-guide.md)로 따로 분리했다.
- 운영 절차와 명령어는 축약하지 않았다.

현재 기준 운영 범위:

- 운영 표준
  - `NodeGroup-A / worker-egress`
  - `Basic Auth -> node-token -> node-bundle`
  - `split DNS`
- 확장 설계
  - `Gateway VM`
  - `Pod sidecar`

표기 원칙:

- `템플릿`: 운영 절차의 기본형
- `실환경 예시`: 현재 검증 환경에서 바로 쓸 수 있었던 명령
- 운영 문서에서는 가능하면 템플릿 설명을 먼저 두고 실환경 예시는 보조로 둔다

## 10. 인증서 갱신 / 폐기 / 교체

### 10.1 운영 원칙

- CA 만료: `5~10년`
- 서버/게이트웨이/노드 cert: `180~397일`
- Pod sidecar cert: `30~90일`
- `만료 직전 갱신`보다 `사전 재발급 + 교체 + 기존 폐기` 절차를 권장

개체별 권장 단위:

- `OpenVPN Server`: 서버별 고유 cert
- `VPN Gateway VM`: VM별 고유 cert
- `worker node client`: node별 고유 cert
- `Pod sidecar`: 기본은 `workload별 고유 cert`, 필요 시 더 짧은 주기의 `pod별 cert`

실무 판단:

- `worker node`는 autoscale과 폐기 대응을 위해 `node별 cert`가 맞다
- `gateway VM`은 대수가 적으므로 `VM별 cert`가 가장 자연스럽다
- `sidecar`는 `pod마다 즉시 새 cert 발급`도 가능하지만 운영 복잡도가 높다
  - 기본 권장은 `workload / deployment 단위 cert`
  - 강한 격리가 필요한 경우에만 `pod별 cert` 자동 발급을 검토한다
- `공유 cert + duplicate-cn` 방식은 운영 표준으로 권장하지 않는다

### 10.2 권장 갱신 방식

실무에서는 아래 방식이 가장 안전하다.

1. 새 CN 또는 버전 suffix로 새 cert 발급
   - 예: `ovpn-node-ng-a-01-2026q2`
2. 새 bundle 배포
3. client restart / rollout restart
4. 접속 확인
5. 기존 cert revoke
6. `gen-crl`
7. 새 `crl.pem`을 서버에 배포
8. 서버에서 OpenVPN `reload-or-restart` 또는 `restart`

예시:

```bash
cd ~/easy-rsa
./easyrsa build-client-full ovpn-node-ng-a-01-2026q2 nopass
./easyrsa revoke ovpn-node-ng-a-01
./easyrsa gen-crl
```

이 방식을 권장하는 이유:

- 패키지별 Easy-RSA renewal helper 차이에 덜 민감
- 롤백이 단순
- 어떤 cert가 현재 운영중인지 추적이 쉽다
- `crl.pem` 재배포와 서비스 반영 단계를 절차에 강제로 포함시키기 쉽다

### 10.3 인증서 폐기

분실/유출 시:

```bash
cd ~/easy-rsa
./easyrsa revoke <CN>
./easyrsa gen-crl
```

서버에 새 CRL 배포:

```bash
scp ~/easy-rsa/pki/crl.pem ovpn-server:/tmp/crl.pem
ssh ovpn-server 'sudo install -m 0644 /tmp/crl.pem /etc/openvpn/server/pki/crl.pem && sudo systemctl restart openvpn-server@server'
```

주의:

- `crl.pem`은 권한 강등 이후에도 읽을 수 있게 보통 `0644`로 유지한다.
- 반대로 서버 개인키와 `tls-crypt.key`는 계속 `0600`을 유지한다.

### 10.4 서버 인증서 교체

```bash
./easyrsa build-server-full ovpn-public-vpc-srv-01-2026q2 nopass
```

교체 순서:

1. 새 cert/key 배포
2. server.conf 파일 경로 변경 또는 symlink 교체
3. `systemctl restart openvpn-server@server`
4. client 재접속 확인
5. 기존 서버 cert revoke
6. CRL 갱신

### 10.5 CA 키 유출 시

이 경우는 `전체 PKI 재구축`이다.

- 새 CA 생성
- 서버 cert 재발급
- 모든 client cert 재발급
- 모든 bundle 재배포
- 서버/클라이언트 순차 교체
- 구 CA trust 제거

즉시 대응해야 하는 사고다.

## 11. 운영 자동화 권장

### 11.1 최소 자동화 범위

- cert 발급 파이프라인
- bundle packaging
- bootstrap `packages endpoint`
- Issuer API
- node/gateway bundle secure distribution
- sidecar secret 갱신
- CRL 배포
- OpenVPN restart / rollout restart

### 11.2 권장 파일 구조

```text
pki/
dist/
  server/
  gateways/
  nodes/
  pods/
bootstrap/
  packages/
  issued/
  revoked/
inventory/
  gateways.yml
  nodes.yml
manifests/
  sidecar/
```

메모:

- `bootstrap/packages/`는 현재 worker 표준에서 필수다.
- `bootstrap/issued/`는 정적 fallback, 확장안, 수동 분석용으로만 두는 선택 경로다.

### 11.3 신규 node / 신규 pod 대응 방향

신규 `worker node`:

- 구현 가능하며, 실무적으로도 자동화 가치가 높다
- 권장 흐름:
  1. node 생성
  2. user script가 `bootstrap packages endpoint`에서 공통 파일을 수신
  3. private IP `Issuer API`에 `Basic Auth -> node-token -> node-bundle` 순서로 요청
  4. OpenVPN client 기동

신규 `Pod sidecar`:

- 구현 가능하지만 node보다 복잡하다
- 선택지:
  1. `workload 단위 cert`
     - Secret 갱신 + rollout restart
  2. `pod 단위 cert`
     - 별도 issuer/controller/operator가 필요
     - 보안성은 높지만 운영비가 크다

권장:

- `node`: 기본은 `Basic Auth -> node-token -> node-bundle` 자동 발급
- `node`: 사전 발급 풀은 fallback, 비상 복구, 수동 분석용으로만 남겨두는 편이 맞다
- `pod`: 기본은 workload 단위, 고보안 요구 시에만 pod 단위 자동 발급

최소 실행 예시:

신규 `worker node`가 Issuer API로 bundle을 받는 경우

템플릿:

```bash
cat >/tmp/node-bundle-request.json <<'EOF'
{
  "node_id":"<NODE_ID>",
  "node_group":"<NODE_GROUP>",
  "role":"worker",
  "cluster":"<CLUSTER_NAME>",
  "metadata":{
    "instance_id":"<INSTANCE_ID>",
    "local_hostname":"<LOCAL_HOSTNAME>",
    "private_ip":"<PRIVATE_IP>"
  }
}
EOF

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/node-token \
  -u "bootstrap:<BOOTSTRAP_PASSWORD>" \
  -H "Content-Type: application/json" \
  --data @/tmp/node-bundle-request.json \
  -o /tmp/node-token-response.json

NODE_TOKEN="$(python3 - <<'PY' /tmp/node-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/node-bundle \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/tmp/node-bundle-request.json \
  -o /tmp/<NODE_ID>.tar.gz
```

실환경 예시:

```bash
cat >/tmp/node-bundle-request.json <<'EOF'
{
  "node_id":"ta-sgh-pri-cls-default-worker-node-10",
  "node_group":"default-worker",
  "role":"worker",
  "cluster":"ta-sgh-pri-cls",
  "metadata":{
    "instance_id":"instance-default-worker-10",
    "local_hostname":"ta-sgh-pri-cls-default-worker-node-10",
    "private_ip":"172.16.200.55"
  }
}
EOF

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/node-token \
  -u "bootstrap:tlsrlgh07" \
  -H "Content-Type: application/json" \
  --data @/tmp/node-bundle-request.json \
  -o /tmp/node-token-response.json

NODE_TOKEN="$(python3 - <<'PY' /tmp/node-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/node-bundle \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/tmp/node-bundle-request.json \
  -o /tmp/ta-sgh-pri-cls-default-worker-node-10.tar.gz
```

신규 `gateway VM` bundle 발급

템플릿:

```bash
cat >/tmp/gateway-bundle-request.json <<'EOF'
{
  "gateway_id":"<GATEWAY_ID>",
  "gateway_group":"gateway-vm",
  "role":"gateway",
  "cluster":"<CLUSTER_NAME>",
  "metadata":{
    "instance_id":"<INSTANCE_ID>",
    "local_hostname":"<LOCAL_HOSTNAME>",
    "private_ip":"<PRIVATE_IP>"
  }
}
EOF

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/gateway-token \
  -u "bootstrap:<BOOTSTRAP_PASSWORD>" \
  -H "Content-Type: application/json" \
  --data @/tmp/gateway-bundle-request.json \
  -o /tmp/gateway-token-response.json

GATEWAY_TOKEN="$(python3 - <<'PY' /tmp/gateway-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/gateway-bundle \
  -H "Authorization: Bearer ${GATEWAY_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/tmp/gateway-bundle-request.json \
  -o /tmp/<GATEWAY_ID>.tar.gz
```

메모:

- 현재 `ta-sgh-ca`에는 `worker node` endpoint만 실제 구현돼 있다.
- `gateway VM`도 운영형으로는 같은 2단계 패턴으로 확장하는 편이 맞다.

신규 `sidecar workload` Secret 갱신

템플릿:

```bash
cat >/tmp/workload-bundle-request.json <<'EOF'
{
  "namespace":"<APP_NAMESPACE>",
  "workload":"<WORKLOAD_NAME>",
  "type":"deployment",
  "bundle_scope":"workload",
  "cluster":"<CLUSTER_NAME>"
}
EOF

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/workload-token \
  -H "Authorization: Bearer <CI_OR_CONTROLLER_BOOTSTRAP_TOKEN>" \
  -H "Content-Type: application/json" \
  --data @/tmp/workload-bundle-request.json \
  -o /tmp/workload-token-response.json

WORKLOAD_TOKEN="$(python3 - <<'PY' /tmp/workload-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert /etc/ssl/certs/bootstrap-root-ca.pem -X POST https://172.16.200.44:8443/v1/bootstrap/workload-bundle \
  -H "Authorization: Bearer ${WORKLOAD_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/tmp/workload-bundle-request.json \
  -o /tmp/workload-bundle.json

python3 - <<'PY'
import base64, json, pathlib
data = json.load(open("/tmp/workload-bundle.json", encoding="utf-8"))
out = pathlib.Path("/tmp/ovpn-workload-bundle")
out.mkdir(exist_ok=True)
for name, content in data["files"].items():
    (out / name).write_bytes(base64.b64decode(content))
PY

kubectl -n <APP_NAMESPACE> delete secret ovpn-client-bundle --ignore-not-found
kubectl -n <APP_NAMESPACE> create secret generic ovpn-client-bundle \
  --from-file=ca.crt=/tmp/ovpn-workload-bundle/ca.crt \
  --from-file=client.crt=/tmp/ovpn-workload-bundle/client.crt \
  --from-file=client.key=/tmp/ovpn-workload-bundle/client.key \
  --from-file=tls-crypt.key=/tmp/ovpn-workload-bundle/tls-crypt.key
kubectl -n <APP_NAMESPACE> rollout restart deployment/<WORKLOAD_NAME>
```

### 11.4 구현 흐름 예시

신규 `worker node` 자동화:

```text
1. node 생성
2. user script 시작
3. private IP `Issuer API`에 bootstrap credential과 metadata로 `node-token` 요청
4. 1회성 token 수신 후 `node-bundle` 요청
5. bundle download / 배치
6. openvpn-client@worker-egress 기동
7. 접속 확인 후 운영 편입
```

실행 예시:

```bash
tar -xzf /tmp/<NODE_ID>.tar.gz -C /etc/openvpn/client/pki
systemctl enable --now openvpn-client@worker-egress
systemctl is-active openvpn-client@worker-egress
```

신규 `gateway VM` 자동화:

```text
1. gateway VM 생성
2. cloud-init 또는 ansible에서 `gateway-token` 요청
3. 1회성 token 수신 후 `gateway-bundle` 요청
4. bundle 배포
5. OpenVPN client 기동
6. 라우팅 / VIP 연결
```

실행 예시:

```bash
tar -xzf /tmp/<GATEWAY_ID>.tar.gz -C /etc/openvpn/client/pki
systemctl enable --now openvpn-client@egress-gw
systemctl is-active openvpn-client@egress-gw
ip route
```

신규 `sidecar workload` 자동화:

```text
1. CI 또는 controller 실행
2. `workload-token` 요청
3. 1회성 token 수신 후 `workload-bundle` 요청
4. Kubernetes Secret 갱신
5. deployment rollout restart
6. sidecar 재기동 후 접속 확인
```

실행 예시:

```bash
kubectl -n <APP_NAMESPACE> rollout restart deployment/<WORKLOAD_NAME>
kubectl -n <APP_NAMESPACE> rollout status deployment/<WORKLOAD_NAME>
kubectl -n <APP_NAMESPACE> logs deploy/<WORKLOAD_NAME> -c vpn --tail=50
```

## 12. 트러블슈팅 문서 안내

- user script, bootstrap endpoint, `split DNS`, `Private URI` image pull, `CoreDNS`, `MTU` 문제는 [06-openvpn-nks-troubleshooting-guide.md](./06-openvpn-nks-troubleshooting-guide.md)에서 본다.
- 운영 문서는 `인증서 / 자동화`, 트러블슈팅 문서는 `장애 원인 분리 / 확인 순서`에 집중하도록 분리했다.

