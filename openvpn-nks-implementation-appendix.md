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

### 4.2 NHN Cloud 네트워크 준비

- Public VPC와 Private VPC 간 `Peering` 생성
- 양쪽 VPC routing table에 상대 VPC CIDR route 추가
  - NHN 문서 기준 한국 리전은 `추가 route 설정`이 필요
- 게이트웨이 VM을 라우트 gateway로 쓸 경우 `source/target check` 비활성화
- HA가 필요하면 `VIP + keepalived` 구조 검토

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

### 5.19 자동 발급 구현 최소 기준

이 문서의 `Issuer API` 섹션은 인터페이스와 운영 원칙을 정의한 것이다. 이 문서만으로 `자동 발급 API 서버`가 이미 구현되는 것은 아니다.

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

dh none
ecdh-curve prime256v1
tls-version-min 1.2
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC

keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup

client-config-dir /etc/openvpn/server/ccd
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/server.log
verb 3
explicit-exit-notify 1
```

메모:

- 여기서는 `redirect-gateway`를 서버에서 일괄 push하지 않는다.
- 클라이언트 종류별로 필요한 route가 달라서 `client config`에서 제어하는 편이 안전하다.

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

권장 검증:

```bash
kubectl -n kube-system get configmap coredns -o yaml
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl exec -it <pod> -- nslookup google.com
kubectl exec -it <pod> -- getent hosts google.com
kubectl exec -it <pod> -- curl -I https://www.google.com
```

추가 확인:

- `nslookup google.com`이 실패하면 `OpenVPN`보다 `CoreDNS upstream`부터 본다
- `curl -I https://www.google.com`만 실패하면 `egress route`, `tun0`, `NAT`, `MTU`를 본다
- 필요하면 `CoreDNS` upstream을 `터널을 통해 도달 가능한 DNS` 또는 `Public VPC에서 허용된 DNS`로 조정한다

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
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
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
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
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
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
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

권장:

- HA가 필요하면 `keepalived + VIP`
- `NodeGroup-B` worker는 `VIP` 또는 `VPN Gateway VM`을 외부 egress next hop으로 사용

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
  --from-file=client.crt=./ovpn-pod-ns1-app1-01.crt \
  --from-file=client.key=./ovpn-pod-ns1-app1-01.key \
  --from-file=tls-crypt.key=./tls-crypt.key
```

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
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
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
- 실제 앱 이미지가 자체 entrypoint를 고정하고 있으면 wrapper 또는 startup script를 별도로 넣어야 한다.
- sidecar feature를 쓰든 일반 multi-container pod를 쓰든 핵심은 `같은 Pod network namespace`를 공유한다는 점이다.

### 9.7 검증

```bash
kubectl -n app-ns exec -it deploy/app-with-ovpn -c vpn -- ip route
kubectl -n app-ns exec -it deploy/app-with-ovpn -c vpn -- ip addr show tun0
kubectl -n app-ns exec -it deploy/app-with-ovpn -c app -- curl -4 https://ifconfig.me
kubectl -n app-ns logs deploy/app-with-ovpn -c vpn
```

