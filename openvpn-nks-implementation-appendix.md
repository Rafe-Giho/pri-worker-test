# NKS OpenVPN 구현 부록

- 이 문서는 [openvpn-nks-build-guide.md](./openvpn-nks-build-guide.md)의 상세 구현 부록이다.
- 기존 가이드의 `## 4. 공통 준비`부터 `## 9. 추가 방안 2 - Pod sidecar OpenVPN client`까지를 원문 그대로 분리했다.
- 명령어, 스크립트, 설정 예시는 축약하지 않았다.

## 4. 공통 준비

### 4.1 보안 그룹/방화벽

OpenVPN 서버 VM:

- inbound: `UDP/<OPENVPN_SERVER_PORT>` from `Private VPC에서 OpenVPN client가 나오는 실제 source 대역`
- inbound: `TCP/22` from 승인된 운영 접근 대역
- outbound: 외부 API 대상 포트 허용

VPN Gateway VM:

- inbound: `worker subnet` 또는 `egress 대상 source 대역`에서 오는 아웃바운드 대상 트래픽 허용
- outbound: `<OPENVPN_SERVER_PRIVATE_IP>:<OPENVPN_SERVER_PORT>/<OPENVPN_PROTO>`

최소 수행 절차:

1. `Public VPC`의 OpenVPN Server VM에 연결된 보안그룹에서 `UDP/<OPENVPN_SERVER_PORT>` inbound를 연다.
2. source는 `Private VPC` 전체보다는 실제 `OpenVPN client가 나오는 subnet` 또는 `gateway subnet`으로 좁힌다.
3. 운영 접속이 필요하면 `TCP/22`는 승인된 운영 접근 대역만 연다.
4. `VPN Gateway VM` 방식이면 gateway VM 보안그룹에서 `worker subnet -> gateway` 경로를 연다.
5. sidecar 방식은 별도 보안그룹보다 `OpenVPN Server`와의 L3 경로, Pod egress 정책, 네임스페이스 정책을 같이 본다.

최소 검증:

- OpenVPN Server에서 `sudo ss -lunp | grep <OPENVPN_SERVER_PORT>`
- client 또는 gateway에서 `nc -vz -u <OPENVPN_SERVER_PRIVATE_IP> <OPENVPN_SERVER_PORT>` 또는 실제 OpenVPN client 기동
- 연결 실패 시 `보안그룹 -> ACL -> route -> OpenVPN 설정` 순서로 본다

### 4.2 NHN Cloud 네트워크 준비

- Public VPC와 Private VPC 간 `Peering` 생성
- 양쪽 VPC routing table에 상대 VPC CIDR route 추가
  - NHN 문서 기준 한국 리전은 `추가 route 설정`이 필요
- 게이트웨이 VM을 라우트 gateway로 쓸 경우 `source/target check` 비활성화
- HA가 필요하면 `VIP + keepalived` 구조 검토

최소 수행 순서:

1. `Public VPC`와 `Private VPC` 사이에 peering을 만든다.
2. `Private VPC route table`에 `Public VPC CIDR -> Peering` route를 넣는다.
3. `Public VPC route table`에 `Private VPC CIDR -> Peering` route를 넣는다.
4. `추가 방안 1`이면 `NodeGroup-B` 전용 subnet 또는 route domain을 준비한다.
5. 그 route table의 기본 외부 경로를 `VPN Gateway VM` 또는 `VIP`로 보낸다.
6. `VPN Gateway VM`을 route gateway로 쓴다면 `source/target check`를 끈다.
7. OpenVPN Server는 peering 경유 `private IP`로 도달되는지 먼저 확인한 뒤 OpenVPN client를 붙인다.

권장 검증:

- worker 또는 gateway에서 `ping <OPENVPN_SERVER_PRIVATE_IP>` 또는 `traceroute <OPENVPN_SERVER_PRIVATE_IP>`
- `ip route get <OPENVPN_SERVER_PRIVATE_IP>`
- `추가 방안 1`이면 `ip route get 8.8.8.8`로 next hop이 gateway VM 쪽으로 잡히는지 확인

## 5. 공통 PKI / CA 서버 구축

실무 권장:

- `CA 서버`는 OpenVPN 서버와 분리
- 가능하면 `offline root / online issuing CA`가 가장 좋다
- 본 문서는 운영 난이도를 낮추기 위해 `전용 issuing CA 1대` 기준으로 쓴다

### 5.1 CA 서버 설치

```bash
sudo apt-get update
sudo apt-get install -y easy-rsa openssl openvpn
umask 077
mkdir -p ~/easy-rsa
cp -a /usr/share/easy-rsa/* ~/easy-rsa/
cd ~/easy-rsa
```

### 5.2 Easy-RSA vars 작성

`~/easy-rsa/vars`

```bash
set_var EASYRSA_ALGO "ec"
set_var EASYRSA_CURVE "prime256v1"
set_var EASYRSA_DIGEST "sha256"
set_var EASYRSA_CA_EXPIRE 3650
set_var EASYRSA_CERT_EXPIRE 397
set_var EASYRSA_CRL_DAYS 30
set_var EASYRSA_DN "cn_only"
set_var EASYRSA_REQ_COUNTRY "KR"
set_var EASYRSA_REQ_PROVINCE "Gyeonggi-do"
set_var EASYRSA_REQ_CITY "Seongnam"
set_var EASYRSA_REQ_ORG "ExampleCorp"
set_var EASYRSA_REQ_EMAIL "netops@example.com"
set_var EASYRSA_REQ_OU "Platform"
```

### 5.3 CA 생성

```bash
cd ~/easy-rsa
./easyrsa init-pki
./easyrsa build-ca
```

주의:

- `ca.key`는 가장 중요한 키다.
- `ca.key`는 CA 서버 밖으로 절대 복사하지 않는다.
- `build-ca` 시 passphrase를 꼭 건다.

### 5.4 서버/클라이언트 인증서 발급

예시 CN 규칙:

- 서버: `ovpn-public-vpc-srv-01`
- 게이트웨이 VM: `ovpn-gw-pri-01`
- 워커 노드: `ovpn-node-ng-a-01`
- 사이드카 Pod: `ovpn-pod-ns1-app1-01`

```bash
cd ~/easy-rsa

./easyrsa build-server-full ovpn-public-vpc-srv-01 nopass
./easyrsa build-client-full ovpn-gw-pri-01 nopass
./easyrsa build-client-full ovpn-node-ng-a-01 nopass
./easyrsa build-client-full ovpn-pod-ns1-app1-01 nopass
./easyrsa gen-crl

openvpn --genkey tls-crypt ~/easy-rsa/pki/private/tls-crypt.key
```

실무 메모:

- daemon용 cert는 보통 `nopass`를 쓴다.
- 대신 `파일권한`, `배포경로`, `CRL`, `짧은 만료주기`로 보완한다.
- 엄격한 보안정책이면 passphrase + systemd askpass/HSM 별도 설계가 필요하다.

### 5.5 배포 번들 생성

서버용 번들:

```bash
install -d -m 0700 ~/dist/server
install -m 0644 ~/easy-rsa/pki/ca.crt ~/dist/server/
install -m 0644 ~/easy-rsa/pki/issued/ovpn-public-vpc-srv-01.crt ~/dist/server/
install -m 0600 ~/easy-rsa/pki/private/ovpn-public-vpc-srv-01.key ~/dist/server/
install -m 0644 ~/easy-rsa/pki/crl.pem ~/dist/server/
install -m 0600 ~/easy-rsa/pki/private/tls-crypt.key ~/dist/server/
```

클라이언트용 번들 예시:

```bash
install -d -m 0700 ~/dist/ovpn-gw-pri-01
install -m 0644 ~/easy-rsa/pki/ca.crt ~/dist/ovpn-gw-pri-01/
install -m 0644 ~/easy-rsa/pki/issued/ovpn-gw-pri-01.crt ~/dist/ovpn-gw-pri-01/client.crt
install -m 0600 ~/easy-rsa/pki/private/ovpn-gw-pri-01.key ~/dist/ovpn-gw-pri-01/client.key
install -m 0600 ~/easy-rsa/pki/private/tls-crypt.key ~/dist/ovpn-gw-pri-01/
```

배포 원칙:

- VM/node bundle은 `scp/ansible/secure bootstrap endpoint`로 배포
- Pod sidecar bundle은 `Kubernetes Secret`으로 배포
- bundle 내부 파일명은 `ca.crt`, `client.crt`, `client.key`, `tls-crypt.key`로 고정한다
  - 개체 식별은 tar.gz 객체명과 실제 cert의 CN으로 한다
  - 내부 파일명을 고정하면 `worker node`, `gateway VM`, `sidecar`가 같은 client config 템플릿을 재사용할 수 있다
- `user script` 안에 PEM을 직접 하드코딩하지 않는다
  - 비밀 유출 위험
  - NKS user script 용량 제한
- `Gateway VM`, `worker node`, `sidecar workload`는 가능한 한 `개체별 고유 cert/key`를 사용한다
- 여러 클라이언트가 `공유 cert`를 쓰거나 `duplicate-cn`으로 중복 세션을 허용하는 방식은 `PoC 임시 편법`으로만 보고 운영 표준으로 쓰지 않는다
  - 누가 접속했는지 추적이 어렵다
  - 한 개체만 폐기(revoke)하기 어렵다
  - 공공기관/감사 대응에서 식별성과 책임 추적성이 약하다

### 5.8 bootstrap endpoint / 번들 배포 구조

이 문서에서 말하는 `bootstrap endpoint`는 `새 node 또는 gateway가 부팅할 때 client bundle을 안전하게 내려받는 고정 배포 엔드포인트`를 뜻한다.

중요:

- `node마다 새로운 endpoint`를 만드는 구조가 아니다
- endpoint는 보통 `1개` 또는 `HA로 2개 이상`의 `고정 URL`로 운영한다
- 새로 만들어지는 것은 `endpoint`가 아니라 `개체별 cert/key와 bundle`이다

권장 구조:

```text
CA Server
  -> cert 발급 / revoke / CRL 생성
  -> bundle packaging
  -> bootstrap repository 또는 배포 서버 업로드

Worker Node / Gateway VM
  -> 고정 bootstrap endpoint 접속
  -> 자기 식별값에 맞는 bundle download
  -> /etc/openvpn/client/pki 배치
  -> OpenVPN client 기동
```

권장 구현:

- endpoint 예시: `https://bootstrap.internal/ovpn/...`
- 접근 제한:
  - Private VPC 내부 접근만 허용
  - nodegroup source 대역 제한
  - 짧은 만료 토큰 또는 mTLS
- bundle 매핑:
  - `nodegroup-role-random`
  - 또는 `gateway-name`

현재 문서의 상태:

- `bootstrap endpoint 방식`까지는 설계에 포함한다
- 하지만 `CA 서버에 실제 endpoint 구현물`이 이미 있다고 가정하지는 않는다
- 운영형으로 가려면 `배포 서버/저장소`, `인증 방식`, `bundle 업로드 절차`를 추가 구현해야 한다

### 5.9 bootstrap endpoint 구현 예시

가장 단순한 구현은 `Private VPC` 안의 별도 bootstrap VM 또는 CA 서버에 `nginx`를 두고, `정적 bundle 저장소`처럼 쓰는 방식이다.

PoC 기준 구성:

```bash
sudo apt-get update
sudo apt-get install -y nginx apache2-utils
sudo install -d -m 0750 /srv/bootstrap/ovpn/issued
sudo install -d -m 0750 /srv/bootstrap/ovpn/revoked
sudo chown -R www-data:www-data /srv/bootstrap/ovpn
```

PoC용 `htpasswd` 생성:

```bash
sudo htpasswd -bc /etc/nginx/.htpasswd-ovpn bootstrap '<BOOTSTRAP_PASSWORD>'
```

`/etc/nginx/sites-available/bootstrap-ovpn.conf`

```nginx
server {
    listen 443 ssl;
    server_name bootstrap.internal;

    ssl_certificate     /etc/nginx/tls/bootstrap.crt;
    ssl_certificate_key /etc/nginx/tls/bootstrap.key;

    location /ovpn/ {
        alias /srv/bootstrap/ovpn/issued/;
        autoindex off;

        allow <PRIVATE_VPC_CIDR>;
        deny all;

        auth_basic "bootstrap";
        auth_basic_user_file /etc/nginx/.htpasswd-ovpn;
    }
}
```

활성화:

```bash
sudo ln -s /etc/nginx/sites-available/bootstrap-ovpn.conf /etc/nginx/sites-enabled/bootstrap-ovpn.conf
sudo nginx -t
sudo systemctl restart nginx
```

운영 권장:

- `Basic Auth`는 PoC까지만
- 운영은 `mTLS` 또는 `짧은 만료 토큰` 기반으로 전환
- 가능하면 `CA 서버`와 `bootstrap endpoint`는 분리

### 5.10 node / gateway bundle 생성 스크립트 예시

`~/easy-rsa/scripts/issue-client-bundle.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

CN="${1:?usage: issue-client-bundle.sh <cn> <type>}"
TYPE="${2:?usage: issue-client-bundle.sh <cn> <type>}"

case "$TYPE" in
  node)    OUTDIR="$HOME/dist/nodes/$CN" ;;
  gateway) OUTDIR="$HOME/dist/gateways/$CN" ;;
  pod)     OUTDIR="$HOME/dist/pods/$CN" ;;
  *) echo "type must be node|gateway|pod" >&2; exit 1 ;;
esac

cd "$HOME/easy-rsa"
./easyrsa build-client-full "$CN" nopass

install -d -m 0700 "$OUTDIR"
install -m 0644 pki/ca.crt "$OUTDIR/"
install -m 0644 "pki/issued/$CN.crt" "$OUTDIR/client.crt"
install -m 0600 "pki/private/$CN.key" "$OUTDIR/client.key"
install -m 0600 pki/private/tls-crypt.key "$OUTDIR/"
cat > "$OUTDIR/bundle-info.txt" <<EOF
CN=$CN
TYPE=$TYPE
EOF

tar -C "$OUTDIR" -czf "$OUTDIR.tar.gz" .
sha256sum "$OUTDIR.tar.gz" > "$OUTDIR.tar.gz.sha256"
```

예시:

```bash
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-node-ng-a-01 node
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-gw-pri-01 gateway
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-pod-ns1-app1-01 pod
```

### 5.11 bootstrap 저장소 업로드 예시

노드 번들을 bootstrap endpoint 경로에 배치:

```bash
sudo install -d -m 0750 /srv/bootstrap/ovpn/issued
sudo cp "$HOME/dist/nodes/ovpn-node-ng-a-01.tar.gz" /srv/bootstrap/ovpn/issued/
sudo cp "$HOME/dist/gateways/ovpn-gw-pri-01.tar.gz" /srv/bootstrap/ovpn/issued/
```

권장 규칙:

- node: `/srv/bootstrap/ovpn/issued/<NODE_ID>.tar.gz`
- gateway: `/srv/bootstrap/ovpn/issued/<GATEWAY_ID>.tar.gz`
- bundle 내부 파일명은 항상 `client.crt`, `client.key`를 사용한다
  - `<NODE_ID>` 또는 `<GATEWAY_ID>`는 tar.gz 객체명 식별용이다
  - 실제 인증서 식별값은 bundle 내부 `bundle-info.txt`의 `CN`과 CA 인덱스로 추적한다
- 폐기된 bundle은 `revoked/`로 이동

### 5.12 sidecar용 Secret 생성 예시

Pod별 즉시 발급보다 `workload 단위 cert`가 더 현실적이다.

예시:

```bash
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-pod-ns1-app1-01 pod

kubectl -n app-ns create secret generic ovpn-client-bundle-app1 \
  --from-file=ca.crt="$HOME/dist/pods/ovpn-pod-ns1-app1-01/ca.crt" \
  --from-file=client.crt="$HOME/dist/pods/ovpn-pod-ns1-app1-01/client.crt" \
  --from-file=client.key="$HOME/dist/pods/ovpn-pod-ns1-app1-01/client.key" \
  --from-file=tls-crypt.key="$HOME/dist/pods/ovpn-pod-ns1-app1-01/tls-crypt.key"
```

### 5.13 자동 발급형 Issuer API 설계안

운영형으로 가면 `정적 bundle 저장소`만으로는 부족할 수 있다. 이때는 `고정된 Issuer API endpoint`가 `신원 검증 -> cert 발급 -> bundle packaging -> 응답`까지 수행하게 만든다.

구성:

```text
Offline Root CA
  -> Issuing CA 서명 / 교체용

Online Issuing CA
  -> 실제 client/server cert 발급

Issuer API
  -> caller 신원 검증
  -> CN / SAN 정책 적용
  -> Easy-RSA 또는 내부 signer 호출
  -> bundle 생성
  -> 응답 또는 저장소 업로드

CRL Publisher
  -> revoke 후 crl.pem 갱신
  -> OpenVPN Server / 배포 저장소 반영

Audit Log
  -> 발급 / 재발급 / 폐기 / 실패 이벤트 기록
```

공공기관/실운영 기준 원칙:

- `Offline Root CA`와 `Online Issuing CA`를 분리
- `Issuer API`는 `Private VPC` 내부에서만 노출
- 발급 요청자는 반드시 식별 가능해야 함
- 발급/폐기 로그는 감사 가능한 형태로 남겨야 함
- `duplicate-cn`은 허용하지 않음

### 5.14 Issuer API endpoint 예시

| Endpoint | 호출 주체 | 용도 | 기본 응답 |
|---|---|---|---|
| `POST /v1/bootstrap/node-bundle` | `worker user script` | node별 cert/bundle 발급 | `tar.gz` 또는 `download_url` |
| `POST /v1/bootstrap/gateway-bundle` | `cloud-init`, `ansible`, 운영자 | gateway VM cert/bundle 발급 | `tar.gz` 또는 `download_url` |
| `POST /v1/bootstrap/workload-bundle` | CI, controller, 운영자 | workload 단위 sidecar bundle 발급 | `JSON + secret payload` 또는 `download_url` |
| `POST /v1/certs/revoke` | 운영자, 자동화 파이프라인 | cert 폐기 | `revoked=true` |
| `POST /v1/crl/publish` | 운영 파이프라인 | 새 `crl.pem` 배포 | `published=true` |

권장:

- `node/gateway`는 `bundle tar.gz` 직접 응답 또는 짧은 만료 `download_url`
- `sidecar`는 `JSON metadata + Secret 생성용 파일 세트` 반환이 다루기 쉽다

### 5.15 요청/응답 예시

Node bundle 요청:

```http
POST /v1/bootstrap/node-bundle
Authorization: Bearer <BOOTSTRAP_TOKEN>
Content-Type: application/json

{
  "node_id": "ng-a-worker-20260403-01",
  "node_group": "nodegroup-a",
  "role": "worker",
  "cluster": "nks-pri-test"
}
```

응답 예시 1. 직접 bundle 반환:

```http
200 OK
Content-Type: application/gzip
Content-Disposition: attachment; filename="ng-a-worker-20260403-01.tar.gz"
```

응답 예시 2. URL 반환:

```json
{
  "cn": "ovpn-node-ng-a-worker-20260403-01",
  "download_url": "https://bootstrap.internal/issued/ng-a-worker-20260403-01.tar.gz?sig=...",
  "expires_at": "2026-04-03T10:05:00Z"
}
```

Workload bundle 요청:

```http
POST /v1/bootstrap/workload-bundle
Authorization: Bearer <ISSUER_API_TOKEN>
Content-Type: application/json

{
  "namespace": "app-ns",
  "workload": "app1",
  "type": "deployment",
  "bundle_scope": "workload"
}
```

응답 예시:

```json
{
  "cn": "ovpn-pod-app-ns-app1-2026q2",
  "files": {
    "ca.crt": "<base64>",
    "client.crt": "<base64>",
    "client.key": "<base64>",
    "tls-crypt.key": "<base64>"
  }
}
```

### 5.16 신원 검증 방법

Node / Gateway:

- `PoC`: 사전 주입된 짧은 만료 bootstrap token
- `운영 권장`: 다음 중 하나
  - 인스턴스 메타데이터 기반 1회성 토큰
  - bootstrap용 mTLS cert
  - 사설망 IP + 추가 토큰의 2중 검증

Sidecar / Workload:

- `CI/CD`가 Issuer API를 호출
- 또는 `cluster 내부 controller`가 `ServiceAccount`로 호출
- Pod가 직접 발급 API를 두드리게 하기보다는 `controller/CI` 경유가 더 안전하다

PoC용 token 생성 예시:

```bash
NODE_TOKEN="$(openssl rand -hex 24)"
GATEWAY_TOKEN="$(openssl rand -hex 24)"
WORKLOAD_TOKEN="$(openssl rand -hex 24)"

jq \
  --arg nt "$NODE_TOKEN" \
  --arg gt "$GATEWAY_TOKEN" \
  --arg wt "$WORKLOAD_TOKEN" \
  '.tokens = {
    ($nt): {"scope":"node","subject":"ng-a-worker-20260403-01"},
    ($gt): {"scope":"gateway","subject":"gw-pri-01"},
    ($wt): {"scope":"workload","subject":"app-ns/app1"}
  }' \
  /opt/ovpn-issuer/tokens.json | sudo tee /opt/ovpn-issuer/tokens.json >/dev/null
```

cluster 내부 controller 또는 운영 검증용 ServiceAccount token 예시:

```bash
kubectl -n app-ns create serviceaccount ovpn-issuer-caller
kubectl -n app-ns create token ovpn-issuer-caller
```

실무 메모:

- `PoC`: 정적 token 파일로 충분하다.
- `운영`: token 1회성 소모, 만료시각, 발급 이력, 호출자 IP 또는 mTLS를 같이 묶는 편이 맞다.

### 5.17 방안별 자동 발급 적용 방법

주 방안 / `User Script`:

```text
node boot
  -> user script
  -> POST /v1/bootstrap/node-bundle
  -> node별 bundle 수신
  -> /etc/openvpn/client/pki 배치
  -> openvpn-client@worker-egress 시작
```

주 방안 / `직접 설치`:

```text
운영자
  -> POST /v1/bootstrap/node-bundle 또는 로컬 발급 스크립트 실행
  -> 번들 수신
  -> 대상 node에 배포
  -> OpenVPN client 시작
```

주 방안 / `DaemonSet`:

```text
DaemonSet Pod
  -> host namespace 진입
  -> POST /v1/bootstrap/node-bundle
  -> host /etc/openvpn/client/pki 배치
  -> host OpenVPN service 재기동
```

추가 방안 1 / `Gateway VM`:

```text
gateway VM boot
  -> cloud-init 또는 ansible
  -> POST /v1/bootstrap/gateway-bundle
  -> gateway별 bundle 수신
  -> OpenVPN client 시작
```

추가 방안 2 / `Sidecar`:

```text
CI 또는 controller
  -> POST /v1/bootstrap/workload-bundle
  -> workload별 bundle 수신
  -> Kubernetes Secret 갱신
  -> rollout restart
```

### 5.18 폐기 / CRL 자동화 흐름

```text
운영자 또는 자동화 파이프라인
  -> POST /v1/certs/revoke
  -> CA에서 revoke 처리
  -> gen-crl
  -> POST /v1/crl/publish
  -> OpenVPN Server에 새 crl.pem 반영
  -> client 재접속 제어
```

권장:

- `node 폐기` 시 해당 cert 즉시 revoke
- `gateway 교체` 시 새 cert 발급 후 기존 cert revoke
- `workload sidecar`는 Secret 교체 후 구 cert revoke

최소 수동 절차:

```bash
cd /opt/easy-rsa
./easyrsa revoke <CN>
./easyrsa gen-crl
sudo install -m 0644 /opt/easy-rsa/pki/crl.pem /srv/bootstrap/ovpn/revoked/crl.pem
scp /opt/easy-rsa/pki/crl.pem ovpn-server:/tmp/crl.pem
ssh ovpn-server 'sudo install -m 0644 /tmp/crl.pem /etc/openvpn/server/pki/crl.pem && sudo systemctl restart openvpn-server@server'
```

최소 자동화 스크립트 예시:

```bash
#!/usr/bin/env bash
set -euo pipefail

CN="${1:?usage: revoke-and-publish.sh <cn>}"

cd /opt/easy-rsa
./easyrsa revoke "$CN"
./easyrsa gen-crl

sudo install -m 0644 pki/crl.pem /srv/bootstrap/ovpn/revoked/crl.pem
scp pki/crl.pem ovpn-server:/tmp/crl.pem
ssh ovpn-server 'sudo install -m 0644 /tmp/crl.pem /etc/openvpn/server/pki/crl.pem && sudo systemctl restart openvpn-server@server'
```

### 5.19 자동 발급 구현 최소 기준

이 문서의 `Issuer API` 섹션은 인터페이스와 운영 원칙만 정의한 것이 아니다. `5.20`부터 `5.26`까지의 배치, 디렉터리 구조, 패키지 설치, 예시 코드, systemd 서비스까지 따라가면 `PoC 수준의 자동 발급 API 서버`는 실제로 구현할 수 있다.

실제로 자동 발급이 동작하려면 최소 아래 4개가 있어야 한다.

- `신원 검증 수단`
  - `node/gateway`: 짧은 만료 bootstrap token, metadata 기반 1회성 토큰, 또는 bootstrap용 mTLS
  - `sidecar/workload`: CI 토큰 또는 cluster 내부 controller의 ServiceAccount
- `발급 실행기`
  - `issue-client-bundle.sh`를 호출해 cert/key/bundle을 만들고 `CN`, `TYPE`, 발급 시각을 로그에 남기는 API 또는 잡
- `배포 저장소`
  - `/srv/bootstrap/ovpn/issued/<ID>.tar.gz` 같은 고정 저장소 또는 직접 응답 방식
- `감사/폐기 연동`
  - 발급 성공/실패 로그
  - `revoke` 후 `crl.pem` 재배포

최소 PoC 흐름:

```text
node boot
  -> user script
  -> 고정 Issuer API 호출
  -> API가 token과 node_id 검증
  -> issue-client-bundle.sh <cn> node 실행
  -> /srv/bootstrap/ovpn/issued/<NODE_ID>.tar.gz 저장 또는 직접 응답
  -> node가 bundle 수신 후 OpenVPN 기동
```

중요:

- 위 최소 구성 전까지는 `자동 발급`이 아니라 `사전 발급된 bundle 다운로드` 방식이다
- 과업 목표인 `curl google.com` 검증만 놓고 보면 `자동 발급`이 필수는 아니다
- 하지만 `autoscale 대응`까지 포함하면 `Issuer API` 또는 동등한 자동 발급 장치가 필요하다

### 5.20 자동 발급 API 서버 권장 배치

이제부터는 `이 문서만으로 PoC 수준의 자동 발급 API 서버를 구현할 수 있는` 기준으로 적는다.

권장 배치:

```text
Private VPC
  +-----------------------------------------------+
  | Issuer Host                                   |
  | - FastAPI / Uvicorn                           |
  | - 짧은 만료 bootstrap token 검증             |
  | - issue-client-bundle.sh 호출                |
  | - /srv/bootstrap/ovpn/issued 저장            |
  +-----------------------------------------------+
                    |
                    v
  +-----------------------------------------------+
  | CA Server                                     |
  | - Easy-RSA / pki                              |
  | - 실제 서명                                   |
  +-----------------------------------------------+
```

PoC에서는 `Issuer Host`와 `CA Server`를 한 VM에 둘 수 있다.

운영 권장:

- `Issuer Host`와 `CA Server`를 분리
- `Issuer Host`는 signer wrapper만 호출
- `CA private key` 접근은 최소화

### 5.21 Issuer Host 디렉터리 구조

```text
/opt/ovpn-issuer/
  app.py
  tokens.json
  logs/
    issuer.log
  venv/

/opt/easy-rsa/
  easyrsa
  pki/
  scripts/
    issue-client-bundle.sh

/srv/bootstrap/ovpn/
  issued/
  revoked/
```

### 5.22 Issuer Host 패키지 설치

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip jq

sudo install -d -m 0750 /opt/ovpn-issuer
sudo install -d -m 0750 /opt/ovpn-issuer/logs
sudo install -d -m 0750 /srv/bootstrap/ovpn/issued
sudo install -d -m 0750 /srv/bootstrap/ovpn/revoked

python3 -m venv /opt/ovpn-issuer/venv
/opt/ovpn-issuer/venv/bin/pip install --upgrade pip
/opt/ovpn-issuer/venv/bin/pip install fastapi uvicorn
```

### 5.23 PoC용 bootstrap token 저장 형식

PoC에서는 아래처럼 정적 token manifest를 둘 수 있다.

`/opt/ovpn-issuer/tokens.json`

```json
{
  "tokens": {
    "node-bootstrap-token-001": {
      "scope": "node",
      "subject": "ng-a-worker-20260403-01"
    },
    "gateway-bootstrap-token-001": {
      "scope": "gateway",
      "subject": "gw-pri-01"
    },
    "workload-issuer-token-001": {
      "scope": "workload",
      "subject": "app-ns/app1"
    }
  }
}
```

운영에서는 이 정적 파일 대신 아래 중 하나로 바꾼다.

- metadata 기반 1회성 token
- bootstrap mTLS
- 별도 token 저장소 또는 DB

### 5.24 Issuer API 서버 예시 코드

아래 예시는 `node`, `gateway`, `workload` 발급을 모두 수행하는 최소 PoC 구현이다.

`/opt/ovpn-issuer/app.py`

```python
import base64
import json
import os
import shutil
import subprocess
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel


APP = FastAPI()

TOKENS_FILE = Path("/opt/ovpn-issuer/tokens.json")
EASYRSA_HOME = Path("/opt/easy-rsa")
ISSUE_SCRIPT = EASYRSA_HOME / "scripts" / "issue-client-bundle.sh"
BOOTSTRAP_DIR = Path("/srv/bootstrap/ovpn/issued")


class NodeBundleRequest(BaseModel):
    node_id: str
    node_group: str
    role: str
    cluster: str


class GatewayBundleRequest(BaseModel):
    gateway_id: str
    role: str = "gateway"


class WorkloadBundleRequest(BaseModel):
    namespace: str
    workload: str
    type: str
    bundle_scope: str = "workload"


def load_tokens() -> dict:
    with TOKENS_FILE.open("r", encoding="utf-8") as fp:
        return json.load(fp)["tokens"]


def verify_token(authorization: str | None, expected_scope: str, expected_subject: str) -> None:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.split(" ", 1)[1]
    tokens = load_tokens()
    entry = tokens.get(token)
    if not entry:
        raise HTTPException(status_code=403, detail="invalid token")
    if entry["scope"] != expected_scope:
        raise HTTPException(status_code=403, detail="scope mismatch")
    if entry["subject"] != expected_subject:
        raise HTTPException(status_code=403, detail="subject mismatch")


def run_issue(cn: str, bundle_type: str) -> Path:
    subprocess.run(
        [str(ISSUE_SCRIPT), cn, bundle_type],
        cwd=str(EASYRSA_HOME),
        check=True,
    )
    if bundle_type == "node":
        bundle_dir = EASYRSA_HOME / "dist" / "nodes" / cn
    elif bundle_type == "gateway":
        bundle_dir = EASYRSA_HOME / "dist" / "gateways" / cn
    else:
        bundle_dir = EASYRSA_HOME / "dist" / "pods" / cn
    return bundle_dir


@APP.get("/healthz")
def healthz():
    return {"ok": True}


@APP.post("/v1/bootstrap/node-bundle")
def node_bundle(req: NodeBundleRequest, authorization: str | None = Header(default=None)):
    verify_token(authorization, "node", req.node_id)
    cn = f"ovpn-node-{req.node_id}"
    bundle_dir = run_issue(cn, "node")
    src = bundle_dir.parent / f"{cn}.tar.gz"
    dst = BOOTSTRAP_DIR / f"{req.node_id}.tar.gz"
    shutil.copy2(src, dst)
    return FileResponse(path=dst, filename=f"{req.node_id}.tar.gz", media_type="application/gzip")


@APP.post("/v1/bootstrap/gateway-bundle")
def gateway_bundle(req: GatewayBundleRequest, authorization: str | None = Header(default=None)):
    verify_token(authorization, "gateway", req.gateway_id)
    cn = f"ovpn-gw-{req.gateway_id}"
    bundle_dir = run_issue(cn, "gateway")
    src = bundle_dir.parent / f"{cn}.tar.gz"
    dst = BOOTSTRAP_DIR / f"{req.gateway_id}.tar.gz"
    shutil.copy2(src, dst)
    return FileResponse(path=dst, filename=f"{req.gateway_id}.tar.gz", media_type="application/gzip")


@APP.post("/v1/bootstrap/workload-bundle")
def workload_bundle(req: WorkloadBundleRequest, authorization: str | None = Header(default=None)):
    subject = f"{req.namespace}/{req.workload}"
    verify_token(authorization, "workload", subject)
    cn = f"ovpn-pod-{req.namespace}-{req.workload}"
    bundle_dir = run_issue(cn, "pod")
    payload = {}
    for name in ("ca.crt", "client.crt", "client.key", "tls-crypt.key"):
        payload[name] = base64.b64encode((bundle_dir / name).read_bytes()).decode("ascii")
    return JSONResponse({"cn": cn, "files": payload})
```

이 예시의 의도:

- `node/gateway`는 `tar.gz` 직접 반환
- `workload`는 Kubernetes Secret 생성이 쉬운 `base64 JSON` 반환
- token 검증은 단순화
- 같은 token의 재사용 차단은 PoC에서 생략

실무 메모:

- 같은 token 재사용 차단이 필요하면 DB 또는 1회성 token 저장소를 둔다
- 발급 이벤트는 별도 파일 또는 syslog로 남긴다
- 운영에서는 `Issuer Host`를 Private VPC에서만 노출한다

### 5.25 systemd 서비스 예시

`/etc/systemd/system/ovpn-issuer.service`

```ini
[Unit]
Description=OpenVPN Bootstrap Issuer API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ovpn-issuer
ExecStart=/opt/ovpn-issuer/venv/bin/uvicorn app:APP --host 0.0.0.0 --port 8443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

기동:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ovpn-issuer
sudo systemctl status ovpn-issuer --no-pager
```

### 5.26 API 동작 검증 예시

Node bundle 요청:

```bash
curl -fsS -X POST http://<ISSUER_HOST_PRIVATE_IP>:8443/v1/bootstrap/node-bundle \
  -H "Authorization: Bearer node-bootstrap-token-001" \
  -H "Content-Type: application/json" \
  --data '{"node_id":"ng-a-worker-20260403-01","node_group":"nodegroup-a","role":"worker","cluster":"nks-pri-test"}' \
  -o /tmp/ng-a-worker-20260403-01.tar.gz
```

Gateway bundle 요청:

```bash
curl -fsS -X POST http://<ISSUER_HOST_PRIVATE_IP>:8443/v1/bootstrap/gateway-bundle \
  -H "Authorization: Bearer gateway-bootstrap-token-001" \
  -H "Content-Type: application/json" \
  --data '{"gateway_id":"gw-pri-01"}' \
  -o /tmp/gw-pri-01.tar.gz
```

Workload bundle 요청:

```bash
curl -fsS -X POST http://<ISSUER_HOST_PRIVATE_IP>:8443/v1/bootstrap/workload-bundle \
  -H "Authorization: Bearer workload-issuer-token-001" \
  -H "Content-Type: application/json" \
  --data '{"namespace":"app-ns","workload":"app1","type":"deployment","bundle_scope":"workload"}'
```

### 5.27 자동 발급 구현 경계

이 섹션까지 적용하면 `PoC 수준의 자동 발급 API 서버`는 구현 가능하다.

즉시 가능한 것:

- node별 자동 발급
- gateway별 자동 발급
- workload별 Secret 생성용 bundle 응답

아직 별도 구현이 필요한 것:

- token 1회성 소모
- metadata 기반 bootstrap token 발급
- 발급 감사 로그 적재
- revoke API와 CRL publish API의 실제 구현
- 고가용성

## 6. 공통 OpenVPN 서버 구축

### 6.1 서버 패키지 설치

```bash
sudo apt-get update
sudo apt-get install -y openvpn iptables-persistent
sudo install -d -m 0750 /etc/openvpn/server/pki
```

메모:

- 문서의 자동화/스크립트 예시는 `apt` 대신 `apt-get` 기준으로 적는다.
  - `apt`는 사람의 대화형 사용에는 편하지만 스크립트 인터페이스 안정성이 떨어진다
  - `cloud-init`, `user script`, 운영 자동화 문서에는 `apt-get`이 더 적합하다
- 기본 이미지에 `iptables` 명령이 이미 있어도 `iptables-persistent`는 규칙 영속화 때문에 따로 필요할 수 있다.
- 이미 `nftables`, `iptables-restore`, `cloud-init`, 구성관리 도구로 규칙 영속화를 처리한다면 `iptables-persistent`는 생략 가능하다.
- OpenVPN 서버 설정을 더 자세히 보려면 [openvpn-server-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-server-build-guide.md)를 참고한다.

번들 복사:

```bash
sudo cp ~/dist/server/* /etc/openvpn/server/pki/
sudo chmod 0644 /etc/openvpn/server/pki/ca.crt /etc/openvpn/server/pki/*.crt /etc/openvpn/server/pki/crl.pem
sudo chmod 0600 /etc/openvpn/server/pki/*.key
```

### 6.2 IP forwarding

`/etc/sysctl.d/99-openvpn.conf`

```conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
```

적용:

```bash
sudo sysctl --system
```

### 6.3 서버 설정

`/etc/openvpn/server/server.conf`

```conf
port <OPENVPN_SERVER_PORT>
proto <OPENVPN_PROTO>
dev tun
topology subnet
server <OPENVPN_TUNNEL_NETWORK> <OPENVPN_TUNNEL_NETMASK>

ca /etc/openvpn/server/pki/ca.crt
cert /etc/openvpn/server/pki/ovpn-public-vpc-srv-01.crt
key /etc/openvpn/server/pki/ovpn-public-vpc-srv-01.key
crl-verify /etc/openvpn/server/pki/crl.pem
tls-crypt /etc/openvpn/server/pki/tls-crypt.key
verify-client-cert require
remote-cert-tls client

dh none
ecdh-curve prime256v1
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305

keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup

status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/server.log
verb 3
```

메모:

- 여기서는 `redirect-gateway`를 서버에서 일괄 push하지 않는다.
- 클라이언트 종류별로 필요한 route가 달라서 `client config`에서 제어하는 편이 안전하다.
- `crl.pem`은 권한 강등 이후에도 읽을 수 있게 `0644`로 두는 편이 일반적이다.
- 더 자세한 directive별 설명과 의도적으로 넣지 않은 값은 [openvpn-server-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-server-build-guide.md)를 기준으로 본다.

### 6.4 서버 NAT

```bash
sudo iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s <OPENVPN_TUNNEL_CIDR> -o eth0 -j MASQUERADE
sudo netfilter-persistent save
```

`eth0`는 실제 인터넷 방향 NIC로 치환한다.

### 6.5 서비스 시작

```bash
sudo systemctl enable --now openvpn-server@server
sudo systemctl status openvpn-server@server
```

### 6.6 서버 점검

```bash
sudo ss -lunp | grep <OPENVPN_SERVER_PORT>
ip addr show tun0
sudo journalctl -u openvpn-server@server -f
```

### 6.7 DNS 설계와 검증

`curl google.com` 목표는 `HTTP egress`만 맞으면 끝나지 않는다. `이름 해석`이 먼저 성공해야 한다.

기본 흐름:

```text
Pod
  -> Cluster DNS Service
  -> CoreDNS
  -> upstream DNS
  -> google.com A/AAAA 응답
  -> 이후 HTTP/HTTPS 트래픽 송신
```

실무 포인트:

- `HTTP 경로`와 `DNS 경로`는 다를 수 있다
- node 또는 gateway에 OpenVPN이 붙어 있어도 `CoreDNS upstream`이 닫혀 있으면 `curl google.com`은 실패한다
- 먼저 `이름 해석 성공`, 그다음 `egress IP 확인` 순서로 검증해야 한다

기본 원칙:

- `NKS`를 쓰는 동안에는 먼저 `CoreDNS`와 기본 `dnsPolicy: ClusterFirst`를 그대로 유지한다
- 즉 `CoreDNS ConfigMap` 수정은 기본값이 아니라 `문제 확인 후 조정하는 단계`로 본다
- DNS 문제를 OpenVPN 문제와 섞지 않기 위해, 먼저 `cluster DNS`, 그다음 `external DNS`, 마지막으로 `HTTP egress` 순서로 본다

### 6.7.1 DNS 관련 작업의 필수 / 필요 / 선택

필수:

- `Pod -> CoreDNS -> upstream DNS` 현재 경로를 먼저 확인한다
- `kubectl exec ... nslookup kubernetes.default.svc.cluster.local`로 cluster DNS가 정상인지 본다
- `kubectl exec ... nslookup google.com`으로 외부 이름 해석이 되는지 본다
- `curl -I https://www.google.com`은 DNS가 된 뒤에 본다

필요:

- 외부 DNS만 실패할 때 `CoreDNS`가 어느 node group에 떠 있는지 확인한다
- `CoreDNS` upstream이 어디를 보는지 확인한다
- 필요한 경우에만 `CoreDNS` upstream을 명시적으로 조정한다
- `NodeGroup-A/B/C`에 따라 DNS 경로와 HTTP 경로가 분리되는지 확인한다

선택:

- 원인 분리를 위해 테스트 Pod에만 `dnsPolicy: None`과 `dnsConfig.nameservers`를 적용한다
- `CoreDNS ConfigMap`을 직접 수정해 명시적 upstream DNS를 넣는다
- sidecar 방식에서 DNS도 터널 경로로 강제할지 별도 실험한다

`CoreDNS`와 유사하게 보면 되는 항목:

- `iptables-persistent`
  - 필수: NAT/FORWARD 규칙이 재부팅 후에도 유지되는 방법 자체
  - 필요: `iptables-persistent` 패키지 사용
  - 선택: `nftables`, `iptables-restore`, `cloud-init`, 구성관리 도구로 대체
- `bootstrap endpoint`
  - 필수: node/gateway가 bundle을 안전하게 받는 경로
  - 필요: 고정 bootstrap endpoint
  - 선택: `Issuer API`로 실시간 발급까지 자동화
- `Issuer API`
  - 필수: 아님
  - 필요: autoscale 대응, node별 자동 발급, workload별 자동 발급이 목표일 때
  - 선택: PoC에서 수동 발급 또는 사전 발급 bundle로 대체
- `Secure Key Manager`
  - 필수: 아님
  - 필요: sidecar Secret의 at-rest 보호를 강화하고 싶을 때
  - 선택: OpenVPN PoC 자체는 SKM 없이도 가능
- `CoreDNS ConfigMap 수정`
  - 필수: 아님
  - 필요: 기본 NKS DNS 경로로 외부 이름 해석이 실제로 안 될 때
  - 선택: 문제 재현이나 PoC 원인 분리용

권장 기본안:

- 클러스터 기본 동작은 `dnsPolicy: ClusterFirst`
- `CoreDNS`는 먼저 기본 NKS 설정을 유지하고 실제 동작을 확인한다
- `forward . /etc/resolv.conf` 경로가 문제를 만들거나 upstream이 불명확할 때만 `명시적 upstream DNS`를 적는 편이 예측 가능하다
- `NodeGroup-A/B/C`를 비교 검증할 때는 `CoreDNS`가 어느 node group에서 뜨는지도 같이 본다

문제 발생 시 조정 예시:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        forward . <UPSTREAM_DNS_1> <UPSTREAM_DNS_2>
        cache 30
        loop
        reload
        loadbalance
    }
```

업스트림 DNS 선택 원칙:

- `Private VPC`나 `Public VPC`에서 허용된 DNS 서버를 쓴다
- `CoreDNS`가 떠 있는 node에서 실제 도달 가능한 DNS여야 한다
- 어떤 DNS를 쓰든 `google.com` 같은 public name을 해석할 수 있어야 한다

방안별 포인트:

- 주 방안 / `NodeGroup-A`
  - test pod가 `NodeGroup-A`에 떠 있어도 `CoreDNS`는 다른 node group에 떠 있을 수 있다
  - 따라서 `HTTP는 VPN`, `DNS는 다른 경로`가 될 수 있다
- 추가 방안 1 / `NodeGroup-B`
  - `NodeGroup-B`의 egress만 `VPN Gateway VM`으로 보내면 `CoreDNS`가 다른 subnet/node group에 있을 때 DNS는 gateway를 타지 않을 수 있다
  - 이 경우 `curl google.com`의 DNS 경로와 HTTP 경로가 분리된다
- 추가 방안 2 / `NodeGroup-C`
  - sidecar로 HTTP egress를 바꿔도 Pod의 기본 DNS는 여전히 `ClusterFirst`일 수 있다
  - sidecar 방식 검증에서는 DNS도 같은 경로로 태울지, cluster DNS를 유지할지 명시해야 한다

PoC에서 가장 단순한 DNS 검증 방법:

- 운영 기본값은 `ClusterFirst`로 두되,
- 원인 분리를 위해 테스트 Pod만 `dnsPolicy: None`과 명시적 `dnsConfig.nameservers`를 써 볼 수 있다

예시:

```yaml
dnsPolicy: None
dnsConfig:
  nameservers:
    - <UPSTREAM_DNS_1>
    - <UPSTREAM_DNS_2>
  searches:
    - svc.cluster.local
```

주의:

- 위 방식은 `PoC에서 DNS 경로를 격리`할 때 유용하다
- 운영 기본값으로 무조건 쓰는 방식은 아니다

권장 검증:

```bash
kubectl -n kube-system get configmap coredns -o yaml
kubectl -n kube-system get pods -o wide -l k8s-app=kube-dns
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl exec -it <pod> -- nslookup kubernetes.default.svc.cluster.local
kubectl exec -it <pod> -- nslookup google.com
kubectl exec -it <pod> -- getent hosts google.com
kubectl exec -it <pod> -- curl -I https://www.google.com
```

추가 확인:

- `nslookup google.com`이 실패하면 `OpenVPN`보다 `CoreDNS upstream`부터 본다
- `curl -I https://www.google.com`만 실패하면 `egress route`, `tun0`, `NAT`, `MTU`를 본다
- 필요하면 `CoreDNS` upstream을 `터널을 통해 도달 가능한 DNS` 또는 `Public VPC에서 허용된 DNS`로 조정한다
- `kubernetes.default.svc.cluster.local`은 되는데 `google.com`만 안 되면 외부 DNS upstream 문제일 가능성이 높다
- test pod에 `dnsPolicy: None`을 줬더니 성공하면, VPN보다 `Cluster DNS 경로`가 원인일 가능성이 높다

## 7. 주 방안 - 각 worker node에 OpenVPN client

### 7.1 세부 방안 평가

| 세부 방안 | 가능 여부 | 적합도 | 판단 |
|---|---:|---:|---|
| 사용자 스크립트 이용 Auto Scale 대응 | 가능 | 높음 | NKS 환경과 가장 잘 맞는다. 신규 node에도 자동 반영할 수 있다. |
| 직접 설치 | 가능 | 중 | PoC, 장애 분석, 단기 검증에는 유용하다. 운영 표준으로 쓰기엔 반복 작업이 많다. |
| DaemonSet 등 자동 설치 | 조건부 가능 | 낮음 | `hostNetwork`, `privileged`, `NET_ADMIN`, host route 수정이 필요해 운영성이 나쁘다. |

### 7.2 적용 대상

- 특정 `전용 node group`만 VPN egress를 타게 할 것
- node 단위 정책이 더 단순할 것
- gateway VM을 따로 운영하지 않을 것

비권장:

- 공용 node group 전체
- kube-system workload와 업무 workload가 섞인 node group

### 7.3 핵심 주의사항

- `NKS user script`는 worker node 초기화 중 root 권한으로 실행된다.
- node 수만큼 OpenVPN 세션이 생긴다.
- kubelet, containerd, image pull, DNS, 내부 통신에 영향이 갈 수 있다.
- 따라서 `내부 CIDR bypass route`를 반드시 넣는다.

### 7.4 인증서 배포 방식

운영 권장:

- user script에서 `secure bootstrap endpoint`로 node별 bundle을 fetch
- endpoint는 `고정 URL`로 운영하고, node마다 새로운 endpoint를 만들지 않는다
- bundle 이름은 `hostname`보다 `nodegroup-role-random` 또는 `사전 할당된 node id`로 매핑하는 편이 낫다
- worker node마다 `고유 cert/key`를 발급한다
- `duplicate-cn`은 쓰지 않는다

권장하지 않음:

- PEM 파일을 user script 본문에 직접 inline
- 여러 worker node가 같은 cert/key를 공유

실무 메모:

- Auto Scale까지 고려하면 두 방식 중 하나를 택한다
  1. `사전 발급 풀`
     - nodegroup별로 미리 여러 개의 cert/bundle을 만들어 둔다
     - 신규 node는 bootstrap endpoint에서 빈 bundle 하나를 할당받는다
  2. `발급 자동화 API`
     - 승인된 bootstrap client만 CSR 제출 또는 bundle 요청 가능
     - CA 또는 중간 발급 서비스가 즉시 발급 후 반환한다

공공기관/보안 민감 고객 기준 권장:

- `개체별 고유 cert/key`
- `duplicate-cn 비활성`
- `revoke 가능한 단위`를 최소 `node / gateway / workload`까지 보장

### 7.5 NKS user script 예시

아래는 Ubuntu worker node 기준 예시다.

```bash
#!/bin/bash
set -euxo pipefail

BOOTSTRAP_BASE_URL="https://bootstrap.internal/ovpn"
# NODE_ID는 bundle 객체명 식별값이다. cert CN과 같을 필요는 없다.
NODE_ID="${NODE_ID_OVERRIDE:-$(hostname)}"
NODE_BUNDLE_URL="${BOOTSTRAP_BASE_URL}/issued/${NODE_ID}.tar.gz"
# 실제 운영에서는 아래 토큰 자리에 metadata 기반 발급값 또는 사전 주입된 짧은 만료 토큰을 사용
BOOTSTRAP_TOKEN="<NODE_BOOTSTRAP_TOKEN>"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn ca-certificates curl

install -d -m 0750 /etc/openvpn/client/pki
curl -fsSL -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}" "${NODE_BUNDLE_URL}" -o /root/ovpn-node.tgz
tar -xzf /root/ovpn-node.tgz -C /etc/openvpn/client/pki

cat >/etc/openvpn/client/worker-egress.conf <<EOF
client
dev tun
proto <OPENVPN_PROTO>
remote <OPENVPN_SERVER_PRIVATE_IP> <OPENVPN_SERVER_PORT>
nobind
persist-key
persist-tun

ca /etc/openvpn/client/pki/ca.crt
cert /etc/openvpn/client/pki/client.crt
key /etc/openvpn/client/pki/client.key
tls-crypt /etc/openvpn/client/pki/tls-crypt.key

remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

route-nopull
route <OPENVPN_SERVER_PRIVATE_IP> 255.255.255.255 net_gateway
route <PRIVATE_VPC_NETWORK> <PRIVATE_VPC_NETMASK> net_gateway
route <PUBLIC_VPC_NETWORK> <PUBLIC_VPC_NETMASK> net_gateway
route <NKS_POD_NETWORK> <NKS_POD_NETMASK> net_gateway
route <NKS_SERVICE_NETWORK> <NKS_SERVICE_NETMASK> net_gateway
route 0.0.0.0 128.0.0.0 vpn_gateway
route 128.0.0.0 128.0.0.0 vpn_gateway
EOF

systemctl enable openvpn-client@worker-egress
systemctl restart openvpn-client@worker-egress
```

실무 메모:

- 위 스크립트의 netmask 예시는 CIDR에 맞게 정확히 바꿔야 한다.
- 실제 운영에서는 쉘 문자열 잘라쓰기 대신 `정확한 netmask`를 명시한다.
- 위 예시의 `bootstrap endpoint`는 `고정 URL`이며, 신규 node가 늘어날 때마다 endpoint를 새로 만드는 구조가 아니다.
- 위 예시에서 `NODE_ID`는 `bundle tar.gz 객체명`을 찾기 위한 값이다. 실제 cert 식별은 bundle 내부의 `client.crt`와 CA 인덱스로 수행한다.
- 실제 운영에서는 `BOOTSTRAP_TOKEN`을 user script에 평문으로 넣지 말고, metadata 기반 임시 토큰이나 별도 안전한 bootstrap 절차로 받아야 한다.

자동 발급 Issuer API를 직접 호출하는 예시:

```bash
#!/bin/bash
set -euxo pipefail

ISSUER_URL="http://<ISSUER_HOST_PRIVATE_IP>:8443/v1/bootstrap/node-bundle"
NODE_ID="${NODE_ID_OVERRIDE:-$(hostname)}"
BOOTSTRAP_TOKEN="<NODE_BOOTSTRAP_TOKEN>"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn ca-certificates curl

install -d -m 0750 /etc/openvpn/client/pki

cat >/root/node-bundle-request.json <<EOF
{
  "node_id": "${NODE_ID}",
  "node_group": "nodegroup-a",
  "role": "worker",
  "cluster": "nks-pri-test"
}
EOF

curl -fsS -X POST "${ISSUER_URL}" \
  -H "Authorization: Bearer ${BOOTSTRAP_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/root/node-bundle-request.json \
  -o /root/ovpn-node.tgz

tar -xzf /root/ovpn-node.tgz -C /etc/openvpn/client/pki
```

이 방식은 기존 `정적 download endpoint` 대신 `Issuer API`가 발급과 응답을 직접 수행한다.

실무에서는 아래처럼 명시값을 넣는 편이 안전하다.

```conf
route <OPENVPN_SERVER_PRIVATE_IP> 255.255.255.255 net_gateway
route <PRIVATE_VPC_NETWORK> <PRIVATE_VPC_NETMASK> net_gateway
route <PUBLIC_VPC_NETWORK> <PUBLIC_VPC_NETMASK> net_gateway
route <NKS_POD_NETWORK> <NKS_POD_NETMASK> net_gateway
route <NKS_SERVICE_NETWORK> <NKS_SERVICE_NETMASK> net_gateway
route 0.0.0.0 128.0.0.0 vpn_gateway
route 128.0.0.0 128.0.0.0 vpn_gateway
```

### 7.6 직접 설치 예시

PoC나 장애 분석용으로 특정 worker node 한 대에 수동 설치할 때는 아래 절차를 쓴다.

```bash
sudo apt-get update
sudo apt-get install -y openvpn ca-certificates

sudo install -d -m 0750 /etc/openvpn/client/pki
sudo cp ./ca.crt /etc/openvpn/client/pki/
sudo cp ./client.crt /etc/openvpn/client/pki/
sudo cp ./client.key /etc/openvpn/client/pki/
sudo cp ./tls-crypt.key /etc/openvpn/client/pki/

sudo tee /etc/openvpn/client/worker-egress.conf >/dev/null <<'EOF'
client
dev tun
proto <OPENVPN_PROTO>
remote <OPENVPN_SERVER_PRIVATE_IP> <OPENVPN_SERVER_PORT>
nobind
persist-key
persist-tun

ca /etc/openvpn/client/pki/ca.crt
cert /etc/openvpn/client/pki/client.crt
key /etc/openvpn/client/pki/client.key
tls-crypt /etc/openvpn/client/pki/tls-crypt.key

remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

route-nopull
route <OPENVPN_SERVER_PRIVATE_IP> 255.255.255.255 net_gateway
route <PRIVATE_VPC_NETWORK> <PRIVATE_VPC_NETMASK> net_gateway
route <PUBLIC_VPC_NETWORK> <PUBLIC_VPC_NETMASK> net_gateway
route <NKS_POD_NETWORK> <NKS_POD_NETMASK> net_gateway
route <NKS_SERVICE_NETWORK> <NKS_SERVICE_NETMASK> net_gateway
route 0.0.0.0 128.0.0.0 vpn_gateway
route 128.0.0.0 128.0.0.0 vpn_gateway
EOF

sudo systemctl enable --now openvpn-client@worker-egress
sudo systemctl status openvpn-client@worker-egress
```

### 7.7 DaemonSet 자동 설치 방안 검토

결론부터 말하면 `가능은 하지만 운영 권장안은 아니다`.

이 방식이 성립하려면 DaemonSet Pod가 아래 조건을 만족해야 한다.

- `hostNetwork: true`
- `privileged: true`
- `NET_ADMIN`
- `/dev/net/tun` 접근
- host의 `/etc/openvpn` 또는 대응 디렉터리 수정 권한
- host route 및 systemd service를 건드릴 수 있는 권한

실무에서는 보통 아래 둘 중 하나로 구현한다.

1. `nsenter`로 host namespace에 들어가 host에 OpenVPN client를 설치/재기동
2. Pod 자체를 host network에서 띄우고 host route를 직접 조작

예시 개념 명령:

```bash
nsenter --target 1 --mount --uts --ipc --net --pid -- bash -lc '
  install -d -m 0750 /etc/openvpn/client/pki
  cp /bundle/* /etc/openvpn/client/pki/
  systemctl restart openvpn-client@worker-egress
'
```

최소 실험용 DaemonSet 예시:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ovpn-host-installer
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: ovpn-host-installer
  template:
    metadata:
      labels:
        app: ovpn-host-installer
    spec:
      hostNetwork: true
      hostPID: true
      tolerations:
        - operator: Exists
      volumes:
        - name: host-root
          hostPath:
            path: /
            type: Directory
        - name: bundle
          secret:
            secretName: ovpn-node-bundle
      containers:
        - name: installer
          image: ubuntu:22.04
          securityContext:
            privileged: true
          command:
            - /bin/bash
            - -lc
            - |
              apt-get update
              apt-get install -y openvpn util-linux
              nsenter --target 1 --mount --uts --ipc --net --pid -- bash -lc '
                install -d -m 0750 /etc/openvpn/client/pki
                cp /bundle/* /etc/openvpn/client/pki/
                systemctl restart openvpn-client@worker-egress
              '
              sleep infinity
          volumeMounts:
            - name: host-root
              mountPath: /host
            - name: bundle
              mountPath: /bundle
              readOnly: true
```

주의:

- 이 예시는 `설치 자동화가 technically possible`함을 보여주기 위한 실험용이다.
- 실제 운영용 manifest로 바로 쓰기엔 package install, host drift, PodSecurity 예외가 너무 크다.

비권장 이유:

- host image/package manager 차이에 민감함
- PodSecurity 예외가 큼
- node upgrade 시 drift 관리가 어려움
- 결국 `NKS user script`보다 복잡하다

따라서 DaemonSet은 `설치 자동화 실험용` 정도로만 보고, 운영 기준은 `User Script`를 권장한다.

### 7.8 검증

worker node에서:

```bash
systemctl status openvpn-client@worker-egress
ip route
ip addr show tun0
curl -4 https://ifconfig.me
journalctl -u openvpn-client@worker-egress -f
```

Pod에서:

```bash
kubectl exec -it <pod> -- curl -4 https://ifconfig.me
kubectl exec -it <pod> -- curl -I https://www.google.com
```

### 7.9 운영 팁

- 반드시 `전용 node group`으로 격리한다.
- cluster autoscaler를 쓴다면 신규 node도 같은 bundle fetch 규칙을 따라야 한다.
- node certificate는 `hostname 종속` 대신 `nodegroup-role-random` 방식이 배포 자동화에는 더 낫다.


## 8. 추가 방안 1 - Private VPC VPN Gateway VM(Client)

### 8.1 적용 대상

아래 조건이면 1순위로 선택한다.

- 특정 worker subnet 또는 node group 전체를 OpenVPN egress로 보낼 것
- worker node OS에는 VPN 클라이언트를 직접 넣고 싶지 않을 것
- 운영 단순성이 중요할 것

Gateway VM 수 기준:

- `PoC`: `VPN Gateway VM 1대`로도 충분하다
- `운영`: gateway가 `1대뿐이면` 단일 장애지점이 된다
- `공공기관/실운영`: 가능하면 `2대 이상 + VIP/라우팅 전환`을 권장한다
- cert는 `gateway VM 1대당 1개`가 원칙이다
  - gateway가 1대면 cert도 1개면 된다
  - gateway가 2대면 cert도 2개가 필요하다
- `NodeGroup-B`는 가능하면 `별도 worker subnet` 또는 `별도 route domain`을 가져야 한다
  - 같은 subnet과 같은 route table을 `NodeGroup-A/C`와 공유하면 egress 경로가 섞이기 쉽다
  - `추가 방안 1`은 `NodeGroup-B만 별도 next hop`을 줄 수 있을 때 가장 깔끔하다

### 8.2 구조

```text
NodeGroup-B Pod -> WorkerNode B -> Private VPC Route
               -> next hop = VPN Gateway VM(Client)
               -> OpenVPN Server(Public VPC)
               -> Internet
```

### 8.3 Gateway VM 준비

```bash
sudo apt-get update
sudo apt-get install -y openvpn iptables-persistent
sudo install -d -m 0750 /etc/openvpn/client/pki
```

클라이언트 번들 복사:

```bash
sudo cp ~/dist/ovpn-gw-pri-01/* /etc/openvpn/client/pki/
sudo chmod 0644 /etc/openvpn/client/pki/ca.crt /etc/openvpn/client/pki/*.crt
sudo chmod 0600 /etc/openvpn/client/pki/*.key
```

### 8.4 Gateway VM client 설정

`/etc/openvpn/client/egress-gw.conf`

```conf
client
dev tun
proto <OPENVPN_PROTO>
remote <OPENVPN_SERVER_PRIVATE_IP> <OPENVPN_SERVER_PORT>
nobind
persist-key
persist-tun

ca /etc/openvpn/client/pki/ca.crt
cert /etc/openvpn/client/pki/client.crt
key /etc/openvpn/client/pki/client.key
tls-crypt /etc/openvpn/client/pki/tls-crypt.key

remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

route <OPENVPN_SERVER_PRIVATE_IP> 255.255.255.255 net_gateway
redirect-gateway def1
```

메모:

- `remote`는 가능하면 OpenVPN 서버의 `private IP`를 쓴다.
- `route <server-ip> ... net_gateway`를 넣어 터널 endpoint가 다시 터널로 들어가지 않게 한다.

### 8.5 Gateway VM forwarding / NAT

`/etc/sysctl.d/99-openvpn-gw.conf`

```conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
```

적용:

```bash
sudo sysctl --system
```

worker subnet에서 들어온 트래픽을 tun0로 내보내는 NAT:

```bash
sudo iptables -A FORWARD -i eth0 -o tun0 -s <WORKER_EGRESS_SOURCE_CIDR> -j ACCEPT
sudo iptables -A FORWARD -i tun0 -o eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s <WORKER_EGRESS_SOURCE_CIDR> -o tun0 -j MASQUERADE
sudo netfilter-persistent save
```

### 8.6 서비스 시작

```bash
sudo systemctl enable --now openvpn-client@egress-gw
sudo systemctl status openvpn-client@egress-gw
```

### 8.7 NHN 라우팅

실무 예시:

- `NodeGroup-B`가 속한 worker subnet 또는 route domain의 기본 경로를 `VPN Gateway VM` 또는 `VIP`로 보낸다
- NHN 문서상 peering route는 `instance 또는 virtual IP`를 gateway로 지정할 수 있다
- gateway VM을 route gateway로 쓸 때는 `source/target check`를 끈다
- 같은 subnet을 다른 node group과 공유하면 `NodeGroup-B만 VPN Gateway VM`을 next hop으로 분리하기 어렵다
- gateway VM이 관리 대역, CA/Issuer Host, 내부 API와도 통신해야 한다면 해당 내부 대역은 `redirect-gateway def1`보다 우선하는 route로 남겨 둔다

권장:

- HA가 필요하면 `keepalived + VIP`
- `NodeGroup-B` worker는 `VIP` 또는 `VPN Gateway VM`을 외부 egress next hop으로 사용

최소 수행 순서:

1. `NodeGroup-B`가 붙는 worker subnet 또는 route domain을 식별한다.
2. 그 subnet/route domain에 연결된 route table을 연다.
3. 인터넷 방향 기본 경로 또는 외부 목적지 CIDR 경로의 next hop을 `VPN Gateway VM` 또는 `VIP`로 지정한다.
4. `VPN Gateway VM`에서는 `ip_forward`, `rp_filter=2`, NAT 규칙, OpenVPN client가 모두 먼저 떠 있어야 한다.
5. 같은 route table을 `NodeGroup-A/C`와 공유하지 않는지 다시 확인한다.

최소 검증:

```bash
ip route get 1.1.1.1
ip route get <OPENVPN_SERVER_PRIVATE_IP>
curl -4 https://ifconfig.me
kubectl exec -it <pod> -- curl -4 https://ifconfig.me
```

### 8.8 검증

Gateway VM에서:

```bash
ip route
ip addr show tun0
curl -4 https://ifconfig.me
```

Pod에서:

```bash
kubectl exec -it <pod> -- curl -4 https://ifconfig.me
kubectl exec -it <pod> -- curl -I https://www.google.com
```



## 9. 추가 방안 2 - Pod sidecar OpenVPN client

### 9.1 적용 대상

- 특정 namespace / 특정 app만 VPN egress가 필요
- node 전체 라우팅을 건드리고 싶지 않음
- PodSecurity 예외를 감수할 수 있음

### 9.2 핵심 제약

- sidecar는 app container와 `같은 Pod network namespace`를 쓴다.
- 따라서 sidecar가 route를 바꾸면 app도 영향을 받는다.
- 대신 `NET_ADMIN`, `/dev/net/tun`, hostPath, root 권한이 필요하다.
- Pod Security Restricted/Baseline 환경에서는 막힐 수 있다.

### 9.3 sidecar 이미지

공식 client 전용 이미지에 과도하게 의존하지 말고, 내부 표준 이미지로 직접 빌드하는 것을 권장한다.

`Dockerfile`

```dockerfile
FROM ubuntu:22.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      openvpn iproute2 ca-certificates dumb-init \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/entrypoint.sh"]
```

`entrypoint.sh`

```bash
#!/bin/bash
set -euo pipefail
exec openvpn --config /etc/openvpn/client/client.conf
```

### 9.4 Kubernetes Secret

```bash
kubectl -n app-ns create secret generic ovpn-client-bundle \
  --from-file=ca.crt=./ca.crt \
  --from-file=client.crt=./client.crt \
  --from-file=client.key=./client.key \
  --from-file=tls-crypt.key=./tls-crypt.key
```

메모:

- `NKS Secure Key Manager` 연동을 쓰면 이 Secret은 `etcd 저장 시점`의 암호화에는 도움 된다.
- 하지만 sidecar가 mount 받은 뒤에는 일반 파일처럼 보이므로, runtime secret 노출면을 줄이려면 Pod 권한과 Secret 접근 범위를 별도로 통제해야 한다.
- 즉 `SKM`은 `OpenVPN CA` 대체재가 아니라 `Kubernetes Secret at-rest 보호` 수단으로 이해하는 편이 맞다.

### 9.5 sidecar client 설정

`client.conf`

```conf
client
dev tun
proto <OPENVPN_PROTO>
remote <OPENVPN_SERVER_PRIVATE_IP> <OPENVPN_SERVER_PORT>
nobind
persist-key
persist-tun

ca /etc/openvpn/client/secret/ca.crt
cert /etc/openvpn/client/secret/client.crt
key /etc/openvpn/client/secret/client.key
tls-crypt /etc/openvpn/client/secret/tls-crypt.key

remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

route-nopull
route <OPENVPN_SERVER_PRIVATE_IP> 255.255.255.255 net_gateway
route <PRIVATE_VPC_NETWORK> <PRIVATE_VPC_NETMASK> net_gateway
route <PUBLIC_VPC_NETWORK> <PUBLIC_VPC_NETMASK> net_gateway
route <NKS_POD_NETWORK> <NKS_POD_NETMASK> net_gateway
route <NKS_SERVICE_NETWORK> <NKS_SERVICE_NETMASK> net_gateway
route 0.0.0.0 128.0.0.0 vpn_gateway
route 128.0.0.0 128.0.0.0 vpn_gateway
```

### 9.6 Deployment 예시

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-with-ovpn
  namespace: app-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-with-ovpn
  template:
    metadata:
      labels:
        app: app-with-ovpn
    spec:
      dnsPolicy: ClusterFirst
      volumes:
        - name: tun
          hostPath:
            path: /dev/net/tun
            type: CharDevice
        - name: ovpn-bundle
          secret:
            secretName: ovpn-client-bundle
        - name: ovpn-config
          configMap:
            name: ovpn-client-config
      containers:
        - name: vpn
          image: registry.example.com/platform/openvpn-client:1.0.0
          securityContext:
            runAsUser: 0
            capabilities:
              add: ["NET_ADMIN"]
          volumeMounts:
            - name: tun
              mountPath: /dev/net/tun
            - name: ovpn-bundle
              mountPath: /etc/openvpn/client/secret
              readOnly: true
            - name: ovpn-config
              mountPath: /etc/openvpn/client
              readOnly: true
        - name: app
          image: curlimages/curl:8.7.1
          command:
            - /bin/sh
            - -c
            - |
              until grep -q 'tun0:' /proc/net/dev; do sleep 1; done
              tail -f /dev/null
```

메모:

- 예시 app container는 `tun0`가 뜰 때까지 대기한다.
- 실제 앱이 라우팅 전환 이후에만 떠야 한다면 `tun0` 존재만 보지 말고 default split route가 `tun0`로 바뀌었는지도 별도 확인하는 편이 안전하다.
- 실제 앱 이미지가 자체 entrypoint를 고정하고 있으면 wrapper 또는 startup script를 별도로 넣어야 한다.
- sidecar feature를 쓰든 일반 multi-container pod를 쓰든 핵심은 `같은 Pod network namespace`를 공유한다는 점이다.

### 9.7 검증

```bash
kubectl -n app-ns exec -it deploy/app-with-ovpn -c vpn -- ip route
kubectl -n app-ns exec -it deploy/app-with-ovpn -c vpn -- ip addr show tun0
kubectl -n app-ns exec -it deploy/app-with-ovpn -c app -- curl -4 https://ifconfig.me
kubectl -n app-ns logs deploy/app-with-ovpn -c vpn
```

