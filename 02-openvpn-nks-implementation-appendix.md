# 02. NKS OpenVPN 구현 부록

- 이 문서는 [01-openvpn-nks-build-guide.md](./01-openvpn-nks-build-guide.md)의 상세 구현 문서다.
- 현재 기준 표준 경로는 `NodeGroup-A / worker-egress user script / full-auto Issuer API`다.
- 이 문서는 공통 준비, CA/Bootstrap/bootstrap endpoint, OpenVPN Server, Issuer API, worker 자동발급, gateway VM, sidecar 순서로 읽도록 유지한다.
- 명령어, 스크립트, 설정 예시는 축약하지 않고 운영형 템플릿 기준으로 남긴다.

표기 원칙:

- `템플릿`: 다른 환경에도 그대로 가져갈 수 있는 일반형 예시
- `실환경 예시`: 현재 `ta-sgh-*` 환경에서 실제 검증한 값
- 운영형 절차는 `템플릿`을 기준으로 설명하고, 필요 시 바로 아래에 `실환경 예시`를 둔다

빠른 읽기 순서:

1. `4장` 공통 준비
2. `5장` CA / Bootstrap 준비
3. `6장` OpenVPN Server 검증
4. `6.8`과 [04-openvpn-issuer-api-guide.md](./04-openvpn-issuer-api-guide.md)로 Issuer API 구축
5. `7.5`와 `7.7`로 `NodeGroup-A` 자동발급 검증
6. 필요 시 `8장`, `9장`으로 `Gateway VM`, `sidecar` 확장

## 4. 공통 준비

### 4.1 보안 그룹/방화벽

OpenVPN 서버 VM:

- inbound: `UDP/<OPENVPN_SERVER_PORT>` from `Private VPC에서 OpenVPN client가 나오는 실제 source 대역`
- inbound: `TCP/22` from 승인된 운영 접근 대역
- outbound: 외부 API 대상 포트 허용

CA / Bootstrap / Issuer 서버:

- inbound: `TCP/443` from `worker node / gateway / 운영자` source 대역
- inbound: `TCP/8443` from `Issuer API`를 호출할 `worker node` 또는 해당 nodegroup source 대역
- outbound: `OpenVPN Server`, `NCR/OBS`, 운영 대상 저장소로 필요한 포트 허용

VPN Gateway VM:

- inbound: `worker subnet` 또는 `egress 대상 source 대역`에서 오는 아웃바운드 대상 트래픽 허용
- outbound: `<OPENVPN_SERVER_PRIVATE_IP>:<OPENVPN_SERVER_PORT>/<OPENVPN_PROTO>`

최소 수행 절차:

1. `Public VPC`의 OpenVPN Server VM에 연결된 보안그룹에서 `UDP/<OPENVPN_SERVER_PORT>` inbound를 연다.
2. source는 `Private VPC` 전체보다는 실제 `OpenVPN client가 나오는 subnet` 또는 `gateway subnet`으로 좁힌다.
3. 운영 접속이 필요하면 `TCP/22`는 승인된 운영 접근 대역만 연다.
4. `VPN Gateway VM` 방식이면 gateway VM 보안그룹에서 `worker subnet -> gateway` 경로를 연다.
5. `Issuer API` 자동 발급을 쓰면 `CA / Bootstrap / Issuer` 서버에서 `TCP/8443` inbound를 nodegroup source 대역 기준으로 연다.
6. sidecar 방식은 별도 보안그룹보다 `OpenVPN Server`와의 L3 경로, Pod egress 정책, 네임스페이스 정책을 같이 본다.

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

### 4.3 비인터넷 구간 패키지 설치 원칙

이번 구성에서는 `OpenVPN Server`를 제외한 아래 대상이 인터넷 outbound가 안 되는 것을 전제로 한다.

- `CA / Bootstrap Server`
  - 현재 문서 기준으로 `Issuer API 역할`까지 같은 서버에 둔다
- `worker node`
- `VPN Gateway VM`

따라서 위 대상에는 `apt-get update && apt-get install ...`을 직접 치는 방식 대신, `인터넷이 되는 외부 Ubuntu 22.04 호스트`에서 `.deb`를 내려받아 내부로 반입한 뒤 설치하는 절차를 기본으로 삼는다.

공통 원칙:

- 외부 다운로드 호스트의 OS/아키텍처는 대상과 같게 맞춘다
  - 예: `Ubuntu 22.04 amd64`
- `--download-only`로 받은 `.deb` 묶음에는 의존 패키지도 같이 포함되도록 같은 명령 한 번으로 내려받는다
- 내부 반입 후에는 `apt-get install -y /경로/*.deb`처럼 `로컬 파일 경로`를 직접 지정해 설치한다
- `OpenVPN Server`만 예외적으로 public outbound가 가능하므로 온라인 `apt-get` 예시를 유지한다
- worker user script처럼 `패키지 묶음 자체를 내부 endpoint에서 받아야 하는 대상`은 base image에 최소 fetch 도구(`curl` 또는 동등 기능)가 있어야 한다

외부 다운로드 공통 예시:

```bash
sudo apt-get update
sudo apt-get install -y apt-rdepends

mkdir -p pkg/<BUNDLE_NAME>
cd pkg/<BUNDLE_NAME>

apt-rdepends <PKG_1> <PKG_2> <PKG_3> 2>/dev/null \
  | grep -E '^[a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?$' \
  | sort -u > pkglist.raw

while read -r pkg; do
  if apt-cache show "$pkg" 2>/dev/null | grep -q '^Filename: '; then
    echo "$pkg"
  fi
done < pkglist.raw > pkglist.txt

xargs -a pkglist.txt sudo apt-get install --download-only --reinstall -y \
  -o Dir::Cache::archives="$(pwd)/"

tar czf ../<BUNDLE_NAME>.tar.gz ./*.deb
```

내부 대상 서버 설치 공통 예시:

```bash
mkdir -p ~/inbox
mv <BUNDLE_NAME>.tar.gz ~/inbox/
cd ~/inbox

sudo install -d -m 0750 /root/pkg/<BUNDLE_NAME>
sudo tar xzf <BUNDLE_NAME>.tar.gz -C /root/pkg/<BUNDLE_NAME>
sudo bash -lc 'dpkg -i /root/pkg/<BUNDLE_NAME>/*.deb || true'
sudo bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/<BUNDLE_NAME> --no-download -f install -y'
```

위 예시에서 경로 역할은 아래처럼 구분한다.

- `~/inbox`
  - 외부에서 반입한 `*.tar.gz`를 **처음 올려두는 위치**
  - 일반 사용자 계정(`ubuntu`)으로 업로드하거나 복사하기 쉬운 임시 보관 경로
- `/root/pkg/<BUNDLE_NAME>`
  - `tar.gz`를 풀어 `.deb`를 설치하는 **root 전용 staging 경로**
  - 패키지 설치가 끝난 뒤 계속 보관해야 하는 필수 경로는 아니다

즉, `tar.gz`를 처음부터 `/root/pkg`로 업로드하는 것이 아니라, 보통은 `~/inbox` 같은 작업용 경로에 먼저 올려둔 뒤 `sudo tar xzf ... -C /root/pkg/...`로 푼다.

설치 예시는 `bash -lc 'dpkg -i ... || true'` 후 `apt-get -o Dir::Cache::archives=/root/pkg/<BUNDLE_NAME> --no-download -f install` 형태를 기본으로 쓴다. `/root/pkg/.../*.deb`의 와일드카드는 root 권한 셸 안에서 확장돼야 하므로, 일반 사용자 셸에서 그대로 `sudo dpkg -i /root/pkg/.../*.deb`를 치면 `No such file or directory`가 날 수 있다. 먼저 local `.deb`를 전부 unpack한 뒤, APT가 같은 로컬 디렉터리를 archive cache로 보면서 의존관계를 마무리하게 하기 위해서다.

중요:

- 외부 다운로드 호스트에서 단순 `apt-get install --download-only`만 쓰면, 그 호스트에 이미 설치돼 있던 의존 패키지는 내려받지 않는 경우가 있다.
- 그러면 내부 서버에서 설치할 때 `Need to get ...`가 뜨면서 외부 mirror로 나가려 한다.
- 또한 `apt-rdepends` 결과에는 `debconf-2.0` 같은 virtual package가 섞일 수 있으므로, 문서 기본값은 `apt-cache show ... | grep '^Filename: '`로 **실제 다운로드 가능한 패키지만 다시 거른 뒤** `apt-rdepends + --reinstall`으로 의존 패키지 전체를 강제로 내려받는 방식으로 적는다.
- 내부 대상 서버 설치에는 `--no-download`를 붙여, 번들이 불완전하면 즉시 실패하게 만든다.

반입 경로는 사전에 하나를 고정해야 한다.

- 승인된 운영자 PC에서 `scp` 또는 `sftp`로 대상 VM에 직접 업로드
- 내부 오브젝트 스토리지 또는 파일 서버에 먼저 올린 뒤 private VM이 받아오기
- 장기 운영이면 private apt mirror 또는 내부 아티팩트 저장소 구성

PoC 예시:

```bash
scp ca-server-debs.tar.gz admin@<CA_BOOTSTRAP_SERVER_PRIVATE_IP>:/home/ubuntu/inbox/
scp bootstrap-vm-debs.tar.gz admin@<CA_BOOTSTRAP_SERVER_PRIVATE_IP>:/home/ubuntu/inbox/
scp issuer-host-debs.tar.gz admin@<CA_BOOTSTRAP_SERVER_PRIVATE_IP>:/home/ubuntu/inbox/
```

## 5. 공통 PKI / CA 서버 구축

현재 문서가 전제하는 인스턴스/역할:

- `Public VPC`
  - `OpenVPN Server VM` 1대
- `Private VPC`
  - `CA / Bootstrap Server VM` 1대
    - `Easy-RSA / pki`
    - `nginx bootstrap repo`
    - 필요 시 `Issuer API(FastAPI/Uvicorn)` 역할 포함
  - `NKS Cluster`
    - `NodeGroup-A`
    - `NodeGroup-B`
    - `NodeGroup-C`
  - `VPN Gateway VM` 1대
    - `추가 방안 1` 검증 시 사용

실무 권장:

- `CA 서버`는 OpenVPN 서버와 분리
- 가능하면 `offline root / online issuing CA`가 가장 좋다
- 현재 전제에서는 `CA 서버`, `bootstrap endpoint`, `Issuer API 역할`을 같은 서버로 사용한다
- 본 문서는 운영 난이도를 낮추기 위해 `전용 issuing CA + bootstrap endpoint + Issuer API 역할`을 겸하는 서버 1대 기준으로 쓴다

### 5.1 CA / Bootstrap 서버 설치

```bash
## 외부 다운로드 호스트
sudo apt-get update
sudo apt-get install -y apt-rdepends

mkdir -p ~/pkg/ca-server
cd ~/pkg/ca-server

apt-rdepends easy-rsa openvpn openssl 2>/dev/null \
  | grep -E '^[a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?$' \
  | sort -u > pkglist.raw

while read -r pkg; do
  if apt-cache show "$pkg" 2>/dev/null | grep -q '^Filename: '; then
    echo "$pkg"
  fi
done < pkglist.raw > pkglist.txt

xargs -a pkglist.txt sudo apt-get install --download-only --reinstall -y \
  -o Dir::Cache::archives="$(pwd)/"

tar czf ../ca-server-debs.tar.gz ./*.deb

## CA / Bootstrap 서버
mkdir -p ~/inbox

## 위 파일을 SFTP/콘솔 업로드/수동 반입 등으로 ~/inbox/에 올린 뒤
cd ~/inbox

sudo install -d -m 0750 /root/pkg/ca-server
sudo tar xzf ca-server-debs.tar.gz -C /root/pkg/ca-server
sudo bash -lc 'dpkg -i /root/pkg/ca-server/*.deb || true'
sudo bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/ca-server --no-download -f install -y'

umask 077
mkdir -p ~/easy-rsa
cp -a /usr/share/easy-rsa/* ~/easy-rsa/
cd ~/easy-rsa
```

메모:

- `CA Server`는 인터넷 outbound가 없다는 전제를 반영한 설치 절차다.
- `easy-rsa`는 설치 후 `/usr/share/easy-rsa`에 들어오므로, 그 디렉터리를 작업 홈으로 복사해서 쓴다.
- 현재 전제에서는 `CA Server`와 `bootstrap endpoint`가 같은 서버이므로, `bootstrap-vm-debs.tar.gz`도 같은 서버의 `~/inbox`로 반입한 뒤 같은 방식으로 `/root/pkg/bootstrap-vm`에 풀어 설치하면 된다.
- `ca-server-debs.tar.gz`도 `bootstrap-vm-debs.tar.gz`와 마찬가지로 외부 다운로드 호스트에서 만든 뒤 `CA / Bootstrap Server`의 `~/inbox/`로 반입해 설치한다.

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

OVPN_SERVER_CN="ovpn-public-vpc-srv-01"
BOOTSTRAP_TLS_CN="bootstrap-endpoint"
BOOTSTRAP_ENDPOINT_IP="<BOOTSTRAP_ENDPOINT_PRIVATE_IP>"
GATEWAY_CN="ovpn-gw-pri-01"
WORKER_CN="ovpn-node-ng-a-01"
SIDECAR_CN="ovpn-pod-ns1-app1-01"

./easyrsa build-server-full "${OVPN_SERVER_CN}" nopass
EASYRSA_EXTRA_EXTS="subjectAltName=IP:${BOOTSTRAP_ENDPOINT_IP}" ./easyrsa build-server-full "${BOOTSTRAP_TLS_CN}" nopass
./easyrsa build-client-full "${GATEWAY_CN}" nopass
./easyrsa build-client-full "${WORKER_CN}" nopass
./easyrsa build-client-full "${SIDECAR_CN}" nopass
./easyrsa gen-crl

openvpn --genkey tls-crypt ~/easy-rsa/pki/private/tls-crypt.key
```

실무 메모:

- 위 변수들은 현재 셸 세션에서만 유지된다.
- 새 셸에서 다음 단계를 수행할 때는 값을 다시 선언하거나, 뒤 단계의 예시처럼 리터럴 파일명을 직접 쓰는 편이 안전하다.
- daemon용 cert는 보통 `nopass`를 쓴다.
- 대신 `파일권한`, `배포경로`, `CRL`, `짧은 만료주기`로 보완한다.
- 엄격한 보안정책이면 passphrase + systemd askpass/HSM 별도 설계가 필요하다.
- 현재 기본 전제는 `bootstrap endpoint private IP` 직접 접근이다.
- 따라서 bootstrap HTTPS 인증서에는 `subjectAltName=IP:<BOOTSTRAP_ENDPOINT_PRIVATE_IP>`가 반드시 들어 있어야 한다.

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

bootstrap HTTPS용 번들:

```bash
install -d -m 0700 ~/dist/bootstrap-https
install -m 0644 ~/easy-rsa/pki/ca.crt ~/dist/bootstrap-https/bootstrap-root-ca.pem
install -m 0644 ~/easy-rsa/pki/issued/bootstrap-endpoint.crt ~/dist/bootstrap-https/bootstrap.crt
install -m 0600 ~/easy-rsa/pki/private/bootstrap-endpoint.key ~/dist/bootstrap-https/bootstrap.key
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
- `~/dist/bootstrap-https/bootstrap-root-ca.pem`은 첫 HTTPS bootstrap 전에 node / gateway가 신뢰해야 하므로 `base image bake`, `cloud-init`, `수동 사전 복사` 중 하나로 먼저 배포해야 한다

### 5.6 node / gateway bundle 생성 스크립트 파일 만들기

`~/easy-rsa/scripts/issue-client-bundle.sh`

```bash
install -d -m 0750 ~/easy-rsa/scripts

cat > ~/easy-rsa/scripts/issue-client-bundle.sh <<'EOF'
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

if [[ -f "pki/issued/$CN.crt" && -f "pki/private/$CN.key" ]]; then
  echo "[INFO] existing cert/key found for $CN, package only"
elif [[ -f "pki/reqs/$CN.req" ]]; then
  echo "[ERROR] request file exists but issued cert/key is missing: pki/reqs/$CN.req" >&2
  echo "[ERROR] inspect the previous failed issuance or use a new CN" >&2
  exit 1
else
  ./easyrsa build-client-full "$CN" nopass
fi

install -d -m 0700 "$OUTDIR"
install -m 0644 pki/ca.crt "$OUTDIR/"
install -m 0644 "pki/issued/$CN.crt" "$OUTDIR/client.crt"
install -m 0600 "pki/private/$CN.key" "$OUTDIR/client.key"
install -m 0600 pki/private/tls-crypt.key "$OUTDIR/"
cat > "$OUTDIR/bundle-info.txt" <<INFO
CN=$CN
TYPE=$TYPE
INFO

tar -C "$OUTDIR" -czf "$OUTDIR.tar.gz" .
(cd "$(dirname "$OUTDIR")" && sha256sum "$(basename "$OUTDIR").tar.gz" > "$(basename "$OUTDIR").tar.gz.sha256")
EOF

chmod 0750 ~/easy-rsa/scripts/issue-client-bundle.sh
```

실행:

```bash
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-node-ng-a-01 node
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-gw-pri-01 gateway
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-pod-ns1-app1-01 pod
```

현재처럼 `5.4`에서 이미 같은 CN으로 발급한 뒤라면:

- 정상 동작은 `재발급`이 아니라 `기존 cert/key를 재사용해 tar.gz만 다시 만드는 것`이다.
- 따라서 위 스크립트는 기존 `pki/issued/<CN>.crt`, `pki/private/<CN>.key`가 있으면 발급을 건너뛴다.
- 만약 `pki/reqs/<CN>.req`만 남고 issued/private가 없다면, 이전 발급이 중간 실패한 상태이므로 먼저 그 상태를 확인해야 한다.

### 5.7 worker/gateway runtime package bundle 생성

`OpenVPN`, `curl`, `ca-certificates`가 없는 비인터넷 node / gateway가 bootstrap 단계에서 먼저 설치할 패키지 묶음을 만든다.

```bash
## 외부 다운로드 호스트
sudo apt-get update
sudo apt-get install -y apt-rdepends

mkdir -p ~/pkg/node-runtime
cd ~/pkg/node-runtime

apt-rdepends openvpn ca-certificates curl 2>/dev/null \
  | grep -E '^[a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?$' \
  | sort -u > pkglist.raw

while read -r pkg; do
  if apt-cache show "$pkg" 2>/dev/null | grep -q '^Filename: '; then
    echo "$pkg"
  fi
done < pkglist.raw > pkglist.txt

xargs -a pkglist.txt sudo apt-get install --download-only --reinstall -y \
  -o Dir::Cache::archives="$(pwd)/"

mkdir -p ~/dist/packages/node-runtime-ubuntu2204-amd64
cp ./*.deb ~/dist/packages/node-runtime-ubuntu2204-amd64/
tar -C ~/dist/packages/node-runtime-ubuntu2204-amd64 -czf ~/dist/packages/node-runtime-ubuntu2204-amd64.tar.gz .
(cd ~/dist/packages && sha256sum node-runtime-ubuntu2204-amd64.tar.gz > node-runtime-ubuntu2204-amd64.tar.gz.sha256)
```

생성 후 바로 해야 하는 일:

- 생성물은 외부 다운로드 호스트의 `~/dist/packages/`에만 있으므로, 그대로는 bootstrap endpoint에서 내려줄 수 없다.
- 아래 2개 파일을 `CA / Bootstrap Server`의 `~/inbox/`로 반입한 뒤 검증하고 최종 배치한다.
  - `~/dist/packages/node-runtime-ubuntu2204-amd64.tar.gz`
  - `~/dist/packages/node-runtime-ubuntu2204-amd64.tar.gz.sha256`

`CA / Bootstrap Server`에서의 다음 순서:

```bash
mkdir -p ~/inbox

## 위 2개 파일을 SFTP/콘솔 업로드/수동 반입 등으로 ~/inbox/에 올린 뒤
cd ~/inbox
sha256sum -c node-runtime-ubuntu2204-amd64.tar.gz.sha256

sudo install -d -m 0750 /srv/bootstrap/ovpn/packages
sudo cp "$HOME/inbox/node-runtime-ubuntu2204-amd64.tar.gz" /srv/bootstrap/ovpn/packages/
```

즉, `5.7`의 산출물 최종 위치는 아래와 같다.

- 작업용 반입 경로: `~/inbox/node-runtime-ubuntu2204-amd64.tar.gz`
- bootstrap endpoint 최종 경로: `/srv/bootstrap/ovpn/packages/node-runtime-ubuntu2204-amd64.tar.gz`

이후 worker node / gateway VM은 `7.5`, `8.5` 예시처럼 아래 URL에서 이 파일을 받는다.

- `https://<BOOTSTRAP_ENDPOINT_PRIVATE_IP>/ovpn/packages/node-runtime-ubuntu2204-amd64.tar.gz`

### 5.8 bootstrap endpoint 구현 예시

가장 단순한 구현은 `Private VPC`의 `CA 서버`에 `nginx`를 같이 두고, worker/gateway가 공통으로 참조할 `bootstrap endpoint`를 두는 방식이다.

현재 worker 표준에서 이 endpoint의 역할은 아래처럼 나뉜다.

- 필수:
  - `/ovpn/packages/bootstrap-root-ca.pem`
  - `/ovpn/packages/worker-egress-bootstrap.sh`
  - `/ovpn/packages/node-runtime-ubuntu2204-amd64.tar.gz`
- 선택:
  - `/ovpn/issued/`
  - 정적 bundle fallback, gateway/sidecar 확장, 수동 분석용으로만 남겨둘 수 있다

PoC 기준 구성:

```bash
## 외부 다운로드 호스트
sudo apt-get update
sudo apt-get install -y apt-rdepends

mkdir -p ~/pkg/bootstrap-vm
mkdir -p ~/pkg
cd ~/pkg/bootstrap-vm

apt-rdepends nginx-core apache2-utils 2>/dev/null \
  | grep -E '^[a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?$' \
  | sort -u > pkglist.raw

while read -r pkg; do
  if apt-cache show "$pkg" 2>/dev/null | grep -q '^Filename: '; then
    echo "$pkg"
  fi
done < pkglist.raw > pkglist.txt

cat pkglist.txt

xargs -a pkglist.txt sudo apt-get install --download-only --reinstall -y \
  -o Dir::Cache::archives="$(pwd)/"

ls -1 *.deb | wc -l
tar czf ../bootstrap-vm-debs.tar.gz ./*.deb
(cd .. && sha256sum bootstrap-vm-debs.tar.gz > bootstrap-vm-debs.tar.gz.sha256)

## CA / Bootstrap 서버
mkdir -p ~/inbox

## 위 2개 파일을 SFTP/콘솔 업로드/수동 반입 등으로 ~/inbox/에 올린 뒤
cd ~/inbox

sha256sum -c bootstrap-vm-debs.tar.gz.sha256

sudo rm -rf /root/pkg/bootstrap-vm
sudo install -d -m 0750 /root/pkg/bootstrap-vm
sudo tar xzf bootstrap-vm-debs.tar.gz -C /root/pkg/bootstrap-vm
sudo bash -lc 'dpkg -i /root/pkg/bootstrap-vm/*.deb || true'
sudo bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/bootstrap-vm --no-download -f install -y'

sudo install -d -m 0750 /srv/bootstrap/ovpn/issued
sudo install -d -m 0750 /srv/bootstrap/ovpn/packages
sudo install -d -m 0750 /srv/bootstrap/ovpn/revoked
sudo chown -R www-data:www-data /srv/bootstrap/ovpn

dpkg -l nginx-core nginx-common apache2-utils | grep '^ii'
nginx -v
which htpasswd
```

메모:

- 여기서도 `bootstrap-vm-debs.tar.gz`는 먼저 `~/inbox` 같은 업로드용 작업 경로에 둔다.
- `/root/pkg/bootstrap-vm`은 압축 해제와 `.deb` 설치를 위한 root 전용 staging 경로다.
- 현재 과업에서는 `CA 서버 = bootstrap endpoint`이므로, 실제로는 같은 서버에서 `ca-server-debs.tar.gz`와 `bootstrap-vm-debs.tar.gz`를 각각 `~/inbox`에 반입해 순서대로 설치하면 된다.
- `apt-rdepends` 결과에는 `debconf-2.0` 같은 virtual package가 섞일 수 있으므로, 문서처럼 `apt-cache show ... | grep '^Filename: '`로 실제 다운로드 가능한 패키지만 다시 걸러야 한다.
- `nginx`는 Ubuntu에서 메타 패키지라 `nginx-core`, `nginx-extras`, `nginx-light` 같은 상호 배타적 flavor를 함께 끌어와 충돌할 수 있다. 따라서 bootstrap endpoint 번들은 `nginx`가 아니라 `nginx-core`를 기준으로 만든다.
- `sha256sum` 파일은 번들을 실제로 검증할 위치 기준 basename으로 만들어야 한다. 절대경로나 `../파일명`으로 기록하면 다른 서버의 `~/inbox`에서 `sha256sum -c`가 실패한다.
- 설치 중 `Need to get ...`가 뜨거나 외부 Ubuntu mirror(`archive.ubuntu.com`, `mirror.kakao.com` 등)로 나가려고 하면, `bootstrap-vm-debs.tar.gz`에 의존 패키지가 덜 들어간 것이다.
- 이 경우 내부 서버에서 계속 시도하지 말고, 외부 다운로드 호스트에서 위의 `pkglist.raw -> pkglist.txt 필터링 + apt-rdepends + --reinstall` 절차로 번들을 다시 만든 뒤 재반입한다.
- 정상이라면 `CA / Bootstrap 서버` 설치 단계에서 외부 mirror 접속 시도가 없어야 한다.

사전 배치:

`5.5 배포 번들 생성`이 끝난 상태를 전제로, nginx가 참조할 TLS 파일을 먼저 배치한다.

```bash
sudo install -d -m 0750 /etc/nginx/tls
sudo cp "$HOME/dist/bootstrap-https/bootstrap.crt" /etc/nginx/tls/bootstrap.crt
sudo cp "$HOME/dist/bootstrap-https/bootstrap.key" /etc/nginx/tls/bootstrap.key
sudo chmod 0644 /etc/nginx/tls/bootstrap.crt
sudo chmod 0600 /etc/nginx/tls/bootstrap.key
```

위 파일이 아직 없다면 `5.5 배포 번들 생성`으로 돌아가 `~/dist/bootstrap-https/bootstrap.crt`, `~/dist/bootstrap-https/bootstrap.key`가 먼저 준비돼 있어야 한다.

PoC용 `htpasswd` 생성:

```bash
sudo htpasswd -bc /etc/nginx/.htpasswd-ovpn bootstrap '<BOOTSTRAP_PASSWORD>'
```

`/etc/nginx/sites-available/bootstrap-ovpn.conf`

```nginx
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/tls/bootstrap.crt;
    ssl_certificate_key /etc/nginx/tls/bootstrap.key;

    location /ovpn/issued/ {
        alias /srv/bootstrap/ovpn/issued/;
        autoindex off;

        allow <PRIVATE_VPC_CIDR>;
        deny all;

        auth_basic "bootstrap";
        auth_basic_user_file /etc/nginx/.htpasswd-ovpn;
    }

    location /ovpn/packages/ {
        alias /srv/bootstrap/ovpn/packages/;
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
sudo ln -sf /etc/nginx/sites-available/bootstrap-ovpn.conf /etc/nginx/sites-enabled/bootstrap-ovpn.conf
sudo nginx -t
sudo systemctl restart nginx
```

운영 권장:

- `Basic Auth`는 PoC까지만
- 운영은 `mTLS` 또는 `짧은 만료 토큰` 기반으로 전환
- 현재 과업 전제는 `CA 서버 = bootstrap endpoint` 동거 구성이다
- 장기 운영에서 보안 분리가 더 중요해지면 그때 `CA 서버`와 `bootstrap endpoint`를 분리 검토한다
- 현재 worker 표준은 `정적 bundle download`가 아니라 `packages endpoint + Issuer API` 조합이다
- 따라서 `/ovpn/packages/`는 현재 필수 경로지만, `/ovpn/issued/`는 fallback 또는 확장 경로로만 보면 된다

TLS / 이름해석 전제:

- 현재 기본 전제는 `bootstrap endpoint private IP` 직접 접근이다.
- 따라서 worker / gateway는 `OpenVPN 수립 전`에도 그 private IP로 라우팅 가능해야 한다.
- `bootstrap.crt`는 해당 IP를 SAN에 포함한 상태로 발급돼야 한다.
- public CA가 아니면 worker / gateway base image에 `bootstrap root CA`를 사전 탑재하거나, 첫 `curl` 전에 공개용 CA 인증서를 별도 경로에 배치해야 한다.

도메인이 있다면:

- 내부 DNS에 `bootstrap.internal` 같은 이름을 등록할 수 있다면 FQDN 방식도 가능하다.
- 그 경우 bootstrap 인증서는 `subjectAltName=DNS:bootstrap.internal`으로 발급한다.
- user script의 `BOOTSTRAP_BASE_URL`도 `https://bootstrap.internal/ovpn`처럼 바꾸면 된다.
- 다만 현재 과업은 DNS 의존도를 줄이기 위해 `private IP 직접 접근`을 기본값으로 둔다.

다음 단계 선택:

- `주 방안(각 worker node에 OpenVPN client)`을 진행할 것이면 `6장 -> 6.8 -> 7장`으로 간다.
- `추가 방안 1(VPN Gateway VM)`을 운영형 자동 발급까지 같이 볼 것이면 `6장 -> 6.8 -> 8장`으로 간다.
- `추가 방안 2(sidecar)`를 운영형 자동 발급까지 같이 볼 것이면 `6장 -> 6.8 -> 9장`으로 간다. Secret fallback 예시는 `9.4`에서 본다.

## 6. 공통 OpenVPN 서버 구축

### 6.1 서버 패키지 설치

```bash
sudo apt-get update
sudo apt-get install -y openvpn iptables-persistent
sudo install -d -m 0750 /etc/openvpn/server/pki
sudo install -d -m 0755 /var/log/openvpn
```

메모:

- 문서의 자동화/스크립트 예시는 `apt` 대신 `apt-get` 기준으로 적는다.
  - `apt`는 사람의 대화형 사용에는 편하지만 스크립트 인터페이스 안정성이 떨어진다
  - `cloud-init`, `user script`, 운영 자동화 문서에는 `apt-get`이 더 적합하다
- 기본 이미지에 `iptables` 명령이 이미 있어도 `iptables-persistent`는 규칙 영속화 때문에 따로 필요할 수 있다.
- 이미 `nftables`, `iptables-restore`, `cloud-init`, 구성관리 도구로 규칙 영속화를 처리한다면 `iptables-persistent`는 생략 가능하다.
- OpenVPN 서버 설정을 더 자세히 보려면 [03-openvpn-server-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\03-openvpn-server-build-guide.md)를 참고한다.

번들 준비와 반입:

- `5.5 배포 번들 생성`은 `CA / Bootstrap Server`에서 `~/dist/server/`를 만든다.
- `OpenVPN Server`에서는 그 파일들이 자동으로 생기지 않으므로, 먼저 `OpenVPN Server`의 `~/inbox/server/`로 반입해야 한다.
- 반입 방법은 `SFTP`, 콘솔 파일 업로드, 승인된 파일 전송 방식 중 아무 것이나 사용해도 된다.

OpenVPN Server에서:

```bash
mkdir -p "$HOME/inbox/server"

# 아래 5개 파일을 CA / Bootstrap Server의 ~/dist/server/ 에서
# 현재 OpenVPN Server의 ~/inbox/server/ 로 먼저 반입한다.
# - ca.crt
# - ovpn-public-vpc-srv-01.crt
# - ovpn-public-vpc-srv-01.key
# - crl.pem
# - tls-crypt.key
```

번들 배치:

```bash
sudo install -m 0644 "$HOME/inbox/server/ca.crt" /etc/openvpn/server/pki/ca.crt
sudo install -m 0644 "$HOME/inbox/server/ovpn-public-vpc-srv-01.crt" /etc/openvpn/server/pki/ovpn-public-vpc-srv-01.crt
sudo install -m 0600 "$HOME/inbox/server/ovpn-public-vpc-srv-01.key" /etc/openvpn/server/pki/ovpn-public-vpc-srv-01.key
sudo install -m 0644 "$HOME/inbox/server/crl.pem" /etc/openvpn/server/pki/crl.pem
sudo install -m 0600 "$HOME/inbox/server/tls-crypt.key" /etc/openvpn/server/pki/tls-crypt.key
```

최소 확인:

```bash
ls -l "$HOME/inbox/server"
sudo ls -l /etc/openvpn/server/pki
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
- 더 자세한 directive별 설명과 의도적으로 넣지 않은 값은 [03-openvpn-server-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\03-openvpn-server-build-guide.md)를 기준으로 본다.

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
- 일반적으로는 `OpenVPN client`가 `tun0`를 기본 egress로 잡고, public name도 `tun0` 경유 resolver로 풀리면 `node`에서 `curl google.com`이 되는 것이 맞다
- 다만 현재 `NodeGroup-A / worker-egress` 표준 구성은 `Private URI image pull`까지 같이 만족해야 하므로 `split DNS`를 추가한다
  - `eth0 -> Private DNS`: `openstacklocal`, `container.nhncloud.com`, `nhncloudservice.com`
  - `tun0 -> 외부 DNS`: 그 외 public name

현재 `worker-egress` user script 기준 node DNS 흐름:

```text
private name
  -> systemd-resolved
  -> eth0
  -> Private DNS
  -> NCR / OBS / VPC internal name resolution

public name
  -> systemd-resolved
  -> tun0
  -> approved external resolver
  -> public internet name resolution
```

### 6.7.0 NKS 환경에서 split DNS가 추가되는 이유

일반 원칙부터 보면, `worker`나 `gateway VM`에 `OpenVPN client`를 설치하고 기본 outbound를 `tun0`로 보내면 `node`에서 `curl google.com`은 되는 것이 맞다.

즉 아래 조건만 맞으면 `split DNS` 자체는 필수는 아니다.

- `tun0`가 기본 egress로 잡힌다
- public name 조회가 `tun0` 경유 resolver로 성공한다
- HTTP/HTTPS outbound가 VPN 뒤에서 정상 허용된다

하지만 현재 `NKS Private Worker`의 `NodeGroup-A / worker-egress` 표준 구성은 여기서 한 단계 더 요구한다.

- 같은 node가 `public internet egress`도 해야 한다
- 동시에 `kubelet/containerd`가 `Private URI image pull`도 해야 한다
- 따라서 `private registry / object storage / VPC internal name`은 `eth0`와 `Private DNS`로 남겨야 한다

그래서 현재 표준 구성에서는 `split DNS`를 추가한다.

- `eth0 -> Private DNS`
  - `openstacklocal`
  - `container.nhncloud.com`
  - `nhncloudservice.com`
- `tun0 -> 외부 DNS`
  - 그 외 public name

정리:

- `node에 OpenVPN client를 설치하는 실행 방안` 전체가 `split DNS`를 반드시 요구하는 것은 아니다
- `Private NKS + Private URI image pull + public internet egress`를 같은 node에서 같이 처리할 때 `split DNS`가 사실상 필요해진다
- 현재 표준 경로는 이 전제를 반영해 `split DNS`를 기본값으로 둔다

현재 실환경 검증 범위:

- `NodeGroup-A / worker-egress / full-auto Issuer API / split DNS / Private URI image pull`
- `node`에서 `curl -I https://www.google.com` 성공
- `Private URI image pull` 성공 후 test Pod 생성 성공
- `pod` 내부 `curl -I https://www.google.com` 성공

즉, 현재 가이드의 운영형 해석은 아래 순서가 맞다.

1. `node`에서 `tun0`, `resolvectl query www.google.com`, `curl -I https://www.google.com`, `curl https://ifconfig.me`까지 통과
2. `Private URI`와 `Object Storage` 도메인이 `SGW IP`로 정상 해석돼 test Pod 이미지를 pull
3. `pod`에서 `nslookup kubernetes.default.svc.cluster.local`
4. `pod`에서 `nslookup google.com`
5. 마지막으로 `pod`에서 `curl -I https://www.google.com`

따라서 현재 실환경에서는 `pod`까지 성공했더라도, 다른 환경에 그대로 옮길 때는 여전히 `CoreDNS`와 image pull 경로를 따로 확인해야 한다.

기본 원칙:

- `NKS`를 쓰는 동안에는 먼저 `CoreDNS`와 기본 `dnsPolicy: ClusterFirst`를 그대로 유지한다
- 즉 `CoreDNS ConfigMap` 수정은 기본값이 아니라 `문제 확인 후 조정하는 단계`로 본다
- DNS 문제를 OpenVPN 문제와 섞지 않기 위해, 먼저 `cluster DNS`, 그다음 `external DNS`, 마지막으로 `HTTP egress` 순서로 본다
- `kubernetes.default.svc.cluster.local`, `<svc>.<ns>.svc.cluster.local` 같은 이름은 `CoreDNS`가 클러스터 내부에서 직접 처리한다
- 따라서 현재 `split DNS`는 `cluster.local` 이름 자체를 바꾸는 것이 아니라, `CoreDNS upstream`과 node의 `private/public name resolution` 경로에 영향을 주는 것으로 이해하는 편이 맞다
- `Ingress host`는 `CoreDNS`가 자동 생성하지 않으므로, `Private DNS` 또는 공인 DNS 레코드가 별도로 있어야 한다

### 6.7.1 DNS 관련 작업의 필수 / 필요 / 선택

필수:

- `cluster.local` 이름과 `external domain`을 분리해서 본다
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
  - 필수: node/gateway가 공통 패키지와 bootstrap CA를 안전하게 받는 경로
  - 필요: 고정 bootstrap endpoint
  - 선택: `/ovpn/issued/` 같은 정적 bundle fallback 경로
- `Issuer API`
  - 필수: 현재 표준인 `NodeGroup-A / worker-egress user script / full-auto Issuer API`를 그대로 쓸 때
  - 필요: gateway VM, sidecar도 같은 2단계 자동 발급 패턴으로 확장하고 싶을 때
  - 선택: worker 표준을 쓰지 않고 PoC용 수동 발급 또는 정적 bundle fallback만 유지할 때
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
- `service.cluster.local`은 되는데 `Ingress host`만 안 되면 `CoreDNS`보다 해당 host의 별도 DNS 레코드부터 본다

### 6.8 자동 발급형 Issuer API 연결

현재 운영형 기준의 `NodeGroup-A / worker-egress user script`는 `Issuer API` 자동 발급 기준으로 정리한다.

공통 구축 순서는 아래처럼 읽는 편이 가장 자연스럽다.

1. `5.1 ~ 5.8`로 `CA / Bootstrap Server`와 bootstrap endpoint를 준비한다.
2. `6.1 ~ 6.7`로 `OpenVPN Server`를 먼저 준비하고 서버 자체가 정상인지 확인한다.
3. [04-openvpn-issuer-api-guide.md](./04-openvpn-issuer-api-guide.md)를 따라 `Issuer API`를 구축한다.
4. 다시 이 문서의 `7.5`로 돌아와 `NodeGroup-A / user script` 자동 발급을 검증한다.

즉 `Issuer API`는 `worker 표준`보다 앞서 준비되는 공통 구성이다. 다만 실제 자동 발급을 처음 검증한 대상이 `worker user script`라서, 이 문서에서는 `7장`과 가장 강하게 연결해 설명한다.

이 문서와 [04-openvpn-issuer-api-guide.md](./04-openvpn-issuer-api-guide.md)의 역할은 아래처럼 나눈다.

- 이 문서:
  - worker, gateway, sidecar가 어떤 발급 흐름과 어떤 템플릿을 쓰는지 설명
  - `1차 launcher`, `2차 bootstrap script`, 직접 설치 절차 같은 소비자 측 로직 설명
- [04-openvpn-issuer-api-guide.md](./04-openvpn-issuer-api-guide.md):
  - `ta-sgh-ca`에서 `Issuer API`를 실제로 설치하고 서비스로 띄우는 절차
  - `node-token`, `node-bundle`과 확장 endpoint의 구현 기준 설명

현재 검증 상태:

- `worker node`는 `private IP Issuer API + Basic Auth -> node-token -> node-bundle` 흐름이 실제로 검증 완료됐다.
- `gateway VM / sidecar`도 같은 `token -> bundle` 2단계 패턴으로 구현할 수 있다.
- 다만 현재 `ta-sgh-ca`의 실구현은 `worker node` endpoint까지이므로, `gateway/workload` endpoint는 동일 로직으로 확장 가능한 상태라고 이해하는 편이 맞다.

## 7. 주 방안 - 각 worker node에 OpenVPN client

### 7.1 세부 방안 평가

| 세부 방안 | 가능 여부 | 적합도 | 판단 |
|---|---:|---:|---|
| 사용자 스크립트 이용 Auto Scale 대응 | 가능 | 높음 | 현재 실환경에서 검증 완료된 표준 경로다. 신규 node scale-out 시에도 자동 반영할 수 있다. |
| 직접 설치 | 가능 | 중 | `7.5`와 같은 자동 발급 로직을 수동으로 수행하는 방식이다. PoC, 장애 분석, 단기 검증에는 유용하다. |
| DaemonSet 등 자동 설치 | 조건부 가능 | 낮음 | 이론상 가능하지만 `hostNetwork`, `privileged`, `NET_ADMIN`, host route 수정이 필요해 운영성이 나쁘다. 현재 표준 경로는 아니다. |

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

현재 표준:

- worker node는 `bootstrap endpoint`에서 공통 패키지와 `worker-egress-bootstrap.sh`를 받는다.
- 그 다음 `Issuer API`에 `node-token -> node-bundle` 순서로 요청해 node별 bundle을 동적으로 받는다.
- endpoint는 `고정 URL`로 운영하고, node마다 새로운 endpoint를 만들지 않는다.
- worker node마다 `고유 cert/key`를 발급한다.
- `duplicate-cn`은 쓰지 않는다.

권장하지 않음:

- PEM 파일을 user script 본문에 직접 inline
- 여러 worker node가 같은 cert/key를 공유

실무 메모:

- 이 문서의 `주 방안`은 `발급 자동화 API` 기준으로 설명한다.
- `사전 발급 풀` 또는 정적 bundle download는 PoC fallback, 수동 분석, 비상 복구용으로만 남겨두는 편이 맞다.
- `gateway VM`, `sidecar`도 운영형으로 가려면 결국 같은 2단계 자동 발급 패턴으로 맞추는 편이 정합성이 높다.

공공기관/보안 민감 고객 기준 권장:

- `개체별 고유 cert/key`
- `duplicate-cn 비활성`
- `revoke 가능한 단위`를 최소 `node / gateway / workload`까지 보장

### 7.5 NKS user script 예시

운영 기준으로는 `긴 inline user script`보다 `짧은 launcher + bootstrap 서버의 2차 스크립트` 방식이 더 안전하다.

이유:

- NKS user-data가 multipart로 감싸지는 환경에서는 긴 본문, 여러 `heredoc`, PEM inline이 `userscript.sh=1 byte`처럼 비정상 전달될 수 있다.
- 긴 스크립트를 직접 넣는 대신, user script에는 `다운로드와 실행`만 남기고 실제 설치 로직은 bootstrap 서버의 `worker-egress-bootstrap.sh`로 분리하는 편이 안정적이다.
- fresh node에서도 바로 돌게 하려면 1차는 `curl -k`로 2차를 받고, 2차가 `bootstrap-root-ca.pem`을 먼저 내려받은 뒤 나머지 요청부터 `--cacert`를 쓰는 방식이 가장 단순했다.

#### 7.5.1 CA / Bootstrap Server에 2차 스크립트 배치

`CA / Bootstrap Server`에서 기존 파일을 교체한다. `tee >`가 기존 파일을 덮어쓰므로 `rm`은 선택이지만, 재배포를 분명히 하려면 아래처럼 한 번 지우고 다시 배치한다.

템플릿:

```bash
sudo rm -f /srv/bootstrap/ovpn/packages/worker-egress-bootstrap.sh

sudo tee /srv/bootstrap/ovpn/packages/worker-egress-bootstrap.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
set -euxo pipefail
exec > >(tee -a /var/log/ovpn-user-script.log) 2>&1

BOOTSTRAP_IP="${BOOTSTRAP_IP:?}"
BOOTSTRAP_USER="${BOOTSTRAP_USER:?}"
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:?}"
BOOTSTRAP_BASE_URL="https://${BOOTSTRAP_IP}/ovpn"
BOOTSTRAP_CA="${BOOTSTRAP_CA:-/etc/ssl/certs/bootstrap-root-ca.pem}"
ISSUER_TOKEN_URL="${ISSUER_TOKEN_URL:-https://${BOOTSTRAP_IP}:8443/v1/bootstrap/node-token}"
ISSUER_BUNDLE_URL="${ISSUER_BUNDLE_URL:-https://${BOOTSTRAP_IP}:8443/v1/bootstrap/node-bundle}"
ISSUER_CACERT="${ISSUER_CACERT:-${BOOTSTRAP_CA}}"

NODE_ID="${NODE_ID:?}"
NODE_GROUP="${NODE_GROUP:?}"
CLUSTER_NAME="${CLUSTER_NAME:?}"
NODE_ROLE="${NODE_ROLE:-worker}"
METADATA_INSTANCE_ID="${METADATA_INSTANCE_ID:?}"
METADATA_LOCAL_HOSTNAME="${METADATA_LOCAL_HOSTNAME:?}"
METADATA_PRIVATE_IP="${METADATA_PRIVATE_IP:?}"
OPENVPN_SERVER_IP="${OPENVPN_SERVER_IP:?}"
OPENVPN_SERVER_PORT="${OPENVPN_SERVER_PORT:-1194}"
OPENVPN_PROTO="${OPENVPN_PROTO:-udp}"

PRIVATE_VPC_NETWORK="${PRIVATE_VPC_NETWORK:?}"
PRIVATE_VPC_NETMASK="${PRIVATE_VPC_NETMASK:?}"
PUBLIC_VPC_NETWORK="${PUBLIC_VPC_NETWORK:?}"
PUBLIC_VPC_NETMASK="${PUBLIC_VPC_NETMASK:?}"
NKS_POD_NETWORK="${NKS_POD_NETWORK:?}"
NKS_POD_NETMASK="${NKS_POD_NETMASK:?}"
NKS_SERVICE_NETWORK="${NKS_SERVICE_NETWORK:?}"
NKS_SERVICE_NETMASK="${NKS_SERVICE_NETMASK:?}"
EGRESS_DNS_1="${EGRESS_DNS_1:?}"
EGRESS_DNS_2="${EGRESS_DNS_2:-}"
PRIVATE_DNS_SERVER="${PRIVATE_DNS_SERVER:-}"
PRIVATE_DNS_ROUTE_DOMAINS="${PRIVATE_DNS_ROUTE_DOMAINS:-openstacklocal container.nhncloud.com nhncloudservice.com}"
SERVICE_GATEWAY_NEXT_HOP="${SERVICE_GATEWAY_NEXT_HOP:-}"
SERVICE_GATEWAY_BYPASS_IPS="${SERVICE_GATEWAY_BYPASS_IPS:-}"

RUNTIME_BUNDLE="${RUNTIME_BUNDLE:-node-runtime-ubuntu2204-amd64.tar.gz}"

WORK_DIR="/opt/ovpn-bootstrap"
PKG_DIR="/root/pkg/node-runtime"
OVPN_DIR="/etc/openvpn/client"
OVPN_PKI_DIR="${OVPN_DIR}/pki"

have_runtime_pkgs() {
  dpkg -s openvpn curl ca-certificates >/dev/null 2>&1
}

install -d -m 0755 "${WORK_DIR}"
install -d -m 0755 "${PKG_DIR}"
install -d -m 0755 "${OVPN_DIR}"
install -d -m 0700 "${OVPN_PKI_DIR}"

curl -k -fsSL -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -o "${BOOTSTRAP_CA}" \
  "${BOOTSTRAP_BASE_URL}/packages/bootstrap-root-ca.pem"
chmod 0644 "${BOOTSTRAP_CA}"

if ! have_runtime_pkgs; then
  curl -fsSL --retry 5 --retry-delay 3 --cacert "${BOOTSTRAP_CA}" \
    -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
    -o "${WORK_DIR}/${RUNTIME_BUNDLE}" \
    "${BOOTSTRAP_BASE_URL}/packages/${RUNTIME_BUNDLE}"

  tar xzf "${WORK_DIR}/${RUNTIME_BUNDLE}" -C "${PKG_DIR}"
  bash -lc 'dpkg -i /root/pkg/node-runtime/*.deb || true'

  if ! have_runtime_pkgs; then
    bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/node-runtime --no-download -f install -y || true'
  fi

  have_runtime_pkgs || {
    echo "[ERROR] required runtime packages are still missing after local bundle install"
    exit 1
  }
fi

cat > "${WORK_DIR}/node-bundle-request.json" <<EOF_JSON
{
  "node_id": "${NODE_ID}",
  "node_group": "${NODE_GROUP}",
  "role": "${NODE_ROLE}",
  "cluster": "${CLUSTER_NAME}",
  "metadata": {
    "instance_id": "${METADATA_INSTANCE_ID}",
    "local_hostname": "${METADATA_LOCAL_HOSTNAME}",
    "private_ip": "${METADATA_PRIVATE_IP}"
  }
}
EOF_JSON

curl -fsS --retry 5 --retry-delay 3 --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_TOKEN_URL}" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -H "Content-Type: application/json" \
  --data @"${WORK_DIR}/node-bundle-request.json" \
  -o "${WORK_DIR}/node-token-response.json"

NODE_TOKEN="$(
  python3 - <<'PY' "${WORK_DIR}/node-token-response.json"
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --retry 5 --retry-delay 3 --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_BUNDLE_URL}" \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @"${WORK_DIR}/node-bundle-request.json" \
  -o "${WORK_DIR}/${NODE_ID}.tar.gz"

tar xzf "${WORK_DIR}/${NODE_ID}.tar.gz" -C "${OVPN_PKI_DIR}"

chmod 0644 "${OVPN_PKI_DIR}/ca.crt"
chmod 0644 "${OVPN_PKI_DIR}/client.crt"
chmod 0600 "${OVPN_PKI_DIR}/client.key"
chmod 0600 "${OVPN_PKI_DIR}/tls-crypt.key"

cat > "${OVPN_DIR}/worker-egress.conf" <<EOF_CONF
client
dev tun
proto ${OPENVPN_PROTO}
remote ${OPENVPN_SERVER_IP} ${OPENVPN_SERVER_PORT}
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
route ${OPENVPN_SERVER_IP} 255.255.255.255 net_gateway
route ${PRIVATE_VPC_NETWORK} ${PRIVATE_VPC_NETMASK} net_gateway
route ${PUBLIC_VPC_NETWORK} ${PUBLIC_VPC_NETMASK} net_gateway
route ${NKS_POD_NETWORK} ${NKS_POD_NETMASK} net_gateway
route ${NKS_SERVICE_NETWORK} ${NKS_SERVICE_NETMASK} net_gateway
route 0.0.0.0 128.0.0.0 vpn_gateway
route 128.0.0.0 128.0.0.0 vpn_gateway
EOF_CONF

if [ -n "${SERVICE_GATEWAY_NEXT_HOP}" ]; then
  for ip in ${SERVICE_GATEWAY_BYPASS_IPS}; do
    printf 'route %s 255.255.255.255 %s\n' "${ip}" "${SERVICE_GATEWAY_NEXT_HOP}" >> "${OVPN_DIR}/worker-egress.conf"
  done
fi

systemctl daemon-reload
systemctl enable --now openvpn-client@worker-egress
sleep 5

if command -v resolvectl >/dev/null 2>&1; then
  if [ -n "${PRIVATE_DNS_SERVER}" ]; then
    resolvectl dns eth0 "${PRIVATE_DNS_SERVER}"

    route_domains=()
    for d in ${PRIVATE_DNS_ROUTE_DOMAINS}; do
      route_domains+=("~${d}")
    done
    resolvectl domain eth0 "${route_domains[@]}"
  fi

  if [ -n "${EGRESS_DNS_2}" ]; then
    resolvectl dns tun0 "${EGRESS_DNS_1}" "${EGRESS_DNS_2}"
  else
    resolvectl dns tun0 "${EGRESS_DNS_1}"
  fi
  resolvectl domain tun0 '~.'
  resolvectl flush-caches || true
fi

systemctl status openvpn-client@worker-egress --no-pager || true
ip addr show tun0 || true
journalctl -u systemd-resolved -n 30 --no-pager || true
resolvectl query www.google.com || true
curl -I --max-time 10 https://www.google.com || true
curl --max-time 10 https://ifconfig.me || true
journalctl -u openvpn-client@worker-egress -n 100 --no-pager || true
EOF

sudo chown www-data:www-data /srv/bootstrap/ovpn/packages/worker-egress-bootstrap.sh
sudo chmod 0644 /srv/bootstrap/ovpn/packages/worker-egress-bootstrap.sh
```

#### 7.5.2 NKS에 넣는 실제 user script

NKS 노드그룹에는 아래처럼 짧은 launcher만 넣는다.

템플릿:

```bash
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/ovpn-user-script.log) 2>&1

BOOTSTRAP_IP="<BOOTSTRAP_IP>"
BOOTSTRAP_USER="<BOOTSTRAP_USER>"
BOOTSTRAP_PASSWORD="<BOOTSTRAP_PASSWORD>"
BOOTSTRAP_BASE_URL="https://${BOOTSTRAP_IP}/ovpn"
NODE_ID="$(hostname -s)"
METADATA_INSTANCE_ID="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || hostname -s)"
METADATA_LOCAL_HOSTNAME="$(hostname -s)"
METADATA_PRIVATE_IP="$(hostname -I | awk '{print $1}')"

curl -k -fsSL -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -o /var/tmp/worker-egress-bootstrap.sh \
  "${BOOTSTRAP_BASE_URL}/packages/worker-egress-bootstrap.sh"

chmod 0700 /var/tmp/worker-egress-bootstrap.sh

BOOTSTRAP_IP="${BOOTSTRAP_IP}" \
BOOTSTRAP_USER="${BOOTSTRAP_USER}" \
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD}" \
NODE_ID="${NODE_ID}" \
NODE_GROUP="<NODE_GROUP>" \
CLUSTER_NAME="<CLUSTER_NAME>" \
NODE_ROLE="worker" \
METADATA_INSTANCE_ID="${METADATA_INSTANCE_ID}" \
METADATA_LOCAL_HOSTNAME="${METADATA_LOCAL_HOSTNAME}" \
METADATA_PRIVATE_IP="${METADATA_PRIVATE_IP}" \
OPENVPN_SERVER_IP="<OPENVPN_SERVER_PRIVATE_IP>" \
OPENVPN_SERVER_PORT="<OPENVPN_SERVER_PORT>" \
OPENVPN_PROTO="<OPENVPN_PROTO>" \
PRIVATE_VPC_NETWORK="<PRIVATE_VPC_NETWORK>" \
PRIVATE_VPC_NETMASK="<PRIVATE_VPC_NETMASK>" \
PUBLIC_VPC_NETWORK="<PUBLIC_VPC_NETWORK>" \
PUBLIC_VPC_NETMASK="<PUBLIC_VPC_NETMASK>" \
NKS_POD_NETWORK="<NKS_POD_NETWORK>" \
NKS_POD_NETMASK="<NKS_POD_NETMASK>" \
NKS_SERVICE_NETWORK="<NKS_SERVICE_NETWORK>" \
NKS_SERVICE_NETMASK="<NKS_SERVICE_NETMASK>" \
EGRESS_DNS_1="<APPROVED_DNS_1>" \
EGRESS_DNS_2="<APPROVED_DNS_2>" \
PRIVATE_DNS_SERVER="<PRIVATE_DNS_SERVER>" \
PRIVATE_DNS_ROUTE_DOMAINS="openstacklocal container.nhncloud.com nhncloudservice.com" \
SERVICE_GATEWAY_NEXT_HOP="<SERVICE_GATEWAY_NEXT_HOP>" \
SERVICE_GATEWAY_BYPASS_IPS="<SERVICE_GATEWAY_IP_1> <SERVICE_GATEWAY_IP_2>" \
RUNTIME_BUNDLE="node-runtime-ubuntu2204-amd64.tar.gz" \
/var/tmp/worker-egress-bootstrap.sh
```

실환경 예시:

```bash
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/ovpn-user-script.log) 2>&1

BOOTSTRAP_IP="172.16.200.44"
BOOTSTRAP_USER="bootstrap"
BOOTSTRAP_PASSWORD="tlsrlgh07"
BOOTSTRAP_BASE_URL="https://${BOOTSTRAP_IP}/ovpn"
NODE_ID="$(hostname -s)"
METADATA_INSTANCE_ID="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || hostname -s)"
METADATA_LOCAL_HOSTNAME="$(hostname -s)"
METADATA_PRIVATE_IP="$(hostname -I | awk '{print $1}')"

curl -k -fsSL -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -o /var/tmp/worker-egress-bootstrap.sh \
  "${BOOTSTRAP_BASE_URL}/packages/worker-egress-bootstrap.sh"

chmod 0700 /var/tmp/worker-egress-bootstrap.sh

BOOTSTRAP_IP="${BOOTSTRAP_IP}" \
BOOTSTRAP_USER="${BOOTSTRAP_USER}" \
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD}" \
NODE_ID="${NODE_ID}" \
NODE_GROUP="default-worker" \
CLUSTER_NAME="ta-sgh-pri-cls" \
NODE_ROLE="worker" \
METADATA_INSTANCE_ID="${METADATA_INSTANCE_ID}" \
METADATA_LOCAL_HOSTNAME="${METADATA_LOCAL_HOSTNAME}" \
METADATA_PRIVATE_IP="${METADATA_PRIVATE_IP}" \
OPENVPN_SERVER_IP="192.168.200.25" \
OPENVPN_SERVER_PORT="1194" \
OPENVPN_PROTO="udp" \
PRIVATE_VPC_NETWORK="172.16.0.0" \
PRIVATE_VPC_NETMASK="255.255.0.0" \
PUBLIC_VPC_NETWORK="192.168.200.0" \
PUBLIC_VPC_NETMASK="255.255.255.0" \
NKS_POD_NETWORK="10.100.0.0" \
NKS_POD_NETMASK="255.255.0.0" \
NKS_SERVICE_NETWORK="10.254.0.0" \
NKS_SERVICE_NETMASK="255.255.0.0" \
EGRESS_DNS_1="1.1.1.1" \
EGRESS_DNS_2="8.8.8.8" \
PRIVATE_DNS_SERVER="172.16.0.105" \
PRIVATE_DNS_ROUTE_DOMAINS="openstacklocal container.nhncloud.com nhncloudservice.com" \
SERVICE_GATEWAY_NEXT_HOP="" \
SERVICE_GATEWAY_BYPASS_IPS="" \
RUNTIME_BUNDLE="node-runtime-ubuntu2204-amd64.tar.gz" \
/var/tmp/worker-egress-bootstrap.sh
```

실무 메모:

- 긴 inline user script는 실제 환경에서 `userscript.sh=1 byte`처럼 비정상 전달될 수 있으므로 권장하지 않는다.
- `7.5.1`의 2차 스크립트는 공용 템플릿이고, 실제 환경값과 node별 metadata는 `7.5.2` launcher가 넘겨준다.
- 현재 운영형 자동 발급은 `Basic Auth -> /v1/bootstrap/node-token -> 1회성 token -> /v1/bootstrap/node-bundle` 2단계다.
- 따라서 node별 `BOOTSTRAP_TOKEN`을 launcher에 미리 넣지 않는다. 긴 수명의 bootstrap credential은 `BOOTSTRAP_USER`, `BOOTSTRAP_PASSWORD`다.
- 위 예시는 `NODE_ID=hostname -s`, `METADATA_INSTANCE_ID=/var/lib/cloud/data/instance-id`, `METADATA_PRIVATE_IP=hostname -I 첫 번째 값`이라는 단순 가정을 쓴다.
- 위 예시의 `bootstrap endpoint`는 `고정 URL`이며, 신규 node가 늘어날 때마다 endpoint를 새로 만드는 구조가 아니다.
- `NODE_ID`는 현재 `hostname -s`를 그대로 쓰고, Issuer API는 `metadata.local_hostname == node_id`, `metadata.private_ip == client_ip`, `instance_id 존재`를 먼저 검증한다.
- 위 예시는 `정적 bootstrap repo + Basic Auth` 기준이다. 운영에서는 `mTLS`, `signed URL`, workload identity 기반 검증으로 바꾸는 편이 맞다.
- 1차는 `curl -k`로 2차와 `bootstrap-root-ca.pem`만 가져오고, 실제 bundle/runtime 다운로드부터 `--cacert`를 쓰는 구조다.
- `RUNTIME_BUNDLE` 이름은 node OS에 맞게 맞춰야 한다. 예: `Ubuntu 22.04 -> node-runtime-ubuntu2204-amd64.tar.gz`
- runtime bundle 설치 후 `openvpn`, `curl`, `ca-certificates`가 이미 들어왔으면 `apt-get -f install`을 더 진행하지 않는다. 일부 이미지에서 불필요한 의존성 복구가 다른 패키지까지 건드리며 실패하는 경우가 있었기 때문이다.
- 모든 `node 설치형 OpenVPN client` 방식이 `split DNS`를 요구하는 것은 아니다. 다만 현재 `NodeGroup-A` 운영형은 `Private URI image pull`까지 같이 만족해야 하므로 `split DNS`를 기본값으로 둔다.
- `curl google.com`까지 보려면 `HTTP route`만이 아니라 `DNS uplink`도 같이 잡아야 한다. 현재 `Ubuntu systemd-resolved` 기준 `NodeGroup-A` 운영형 기본값은 `eth0`에 `Private DNS routed domains`, `tun0`에 외부 DNS와 `~.` domain을 두는 `split DNS`다.
- PoC에서는 `1.1.1.1`, `8.8.8.8`로 검증할 수 있지만, 운영에서는 조직 승인 resolver 또는 VPN 뒤에서 도달 가능한 resolver를 넣는 편이 맞다.
- `NCR`, `OBS`, 내부 artifact registry pull은 `Pod`가 아니라 `node의 kubelet/containerd`가 수행한다.
- 운영형 기본값은 `Private DNS`로 `NCR Private Endpoint -> NCR SGW IP`, `Object Storage 도메인 -> OBS SGW IP`를 먼저 보장하는 것이다.
- `Private DNS`가 아직 없다면 이 launcher를 먼저 적용하지 말고, `NCR/OBS image pull 경로`를 별도 문서 기준으로 먼저 정리하는 편이 맞다.
- `SERVICE_GATEWAY_BYPASS_IPS`는 1차 해결책이 아니라, `Private URI`가 이미 `SGW IP`로 정상 해석되는데도 해당 목적지 IP가 `tun0`로 빨려 들어갈 때만 쓰는 예외 옵션이다.

#### 7.5.3 NCR / OBS name resolution 운영 전제와 확인

`NodeGroup-A`의 `worker-egress` 검증 중 `NCR` 또는 `OBS` 이미지 pull이 필요하면, 먼저 `Private URI`가 `SGW IP`로 정상 해석되는지부터 본다.

실환경 예시:

```bash
getent hosts private-c0978417-kr1-registry.container.nhncloud.com
getent hosts kr1-api-object-storage.nhncloudservice.com
```

운영형 기본값:

- `Private DNS`를 먼저 구성해 아래 두 이름이 각 `SGW IP`로 풀리게 한다.
  - `private-<REGISTRY_ID>-kr1-registry.container.nhncloud.com -> <NCR_SGW_IP>`
  - `kr1-api-object-storage.nhncloudservice.com -> <OBS_SGW_IP>`
- `worker-egress` 템플릿은 `split DNS` 기준이므로, 정상이라면 `resolvectl query private-...`가 `link: eth0`로 보여야 한다.
- 이렇게 구성했다면 node user script에는 추가 route 예외가 없어도 된다. `PRIVATE_VPC_NETWORK` bypass route가 이미 `SGW IP`를 `eth0`로 유지하기 때문이다.

메모:

- `Private URI`가 `SGW IP`로 풀리지 않는다면 route보다 name resolution을 먼저 고쳐야 한다.
- timeout, `link: tun0`, 임시 route 예외 같은 장애 처리 흐름은 [06-openvpn-nks-troubleshooting-guide.md](./06-openvpn-nks-troubleshooting-guide.md)에서 본다.
- 현재 실환경에서는 `split DNS` 적용 후 `private-<REGISTRY_ID>...`가 `link: eth0`로 풀렸고, 그 상태에서 image pull이 성공해 test Pod 생성까지 확인했다.

검증:

```bash
sudo wc -c /var/tmp/userscript.sh
sudo sed -n '1,80p' /var/tmp/userscript.sh
sudo tail -n 100 /var/log/ovpn-user-script.log
systemctl status openvpn-client@worker-egress --no-pager
ip addr show tun0
journalctl -u openvpn-client@worker-egress -n 100 --no-pager
resolvectl status
resolvectl query www.google.com
curl -I --max-time 10 https://www.google.com
curl --max-time 10 https://ifconfig.me
```

적용 순서 메모:

- `pod egress`를 보기 전에 `node egress`를 먼저 통과시킨다.
- 먼저 `openvpn-client@worker-egress`가 `active`이고 `tun0`에 `10.8.0.x`가 잡히는지 본다.
- 그 다음 `node`에서 `curl -I https://www.google.com`이 되는지 확인한다.
- `node`가 되더라도 `pod`는 `DNS`, `CNI`, `NetworkPolicy` 영향이 따로 있으므로 별도 검증한다.

자동 발급 Issuer API를 직접 호출하는 예시:

템플릿:

```bash
#!/bin/bash
set -euxo pipefail

ISSUER_TOKEN_URL="https://<ISSUER_API_PRIVATE_IP>:8443/v1/bootstrap/node-token"
ISSUER_BUNDLE_URL="https://<ISSUER_API_PRIVATE_IP>:8443/v1/bootstrap/node-bundle"
ISSUER_CACERT="/etc/ssl/certs/bootstrap-root-ca.pem"
NODE_ID="${NODE_ID_OVERRIDE:-$(hostname -s)}"
RUNTIME_BUNDLE_URL="https://<BOOTSTRAP_ENDPOINT_PRIVATE_IP>/ovpn/packages/node-runtime-ubuntu2204-amd64.tar.gz"
BOOTSTRAP_USER="<BOOTSTRAP_USER>"
BOOTSTRAP_PASSWORD="<BOOTSTRAP_PASSWORD>"
BOOTSTRAP_CACERT="/etc/ssl/certs/bootstrap-root-ca.pem"
NODE_GROUP="<NODE_GROUP>"
CLUSTER_NAME="<CLUSTER_NAME>"
INSTANCE_ID="<INSTANCE_ID_FROM_METADATA>"
LOCAL_HOSTNAME="<LOCAL_HOSTNAME_FROM_METADATA>"
PRIVATE_IP="<PRIVATE_IP_FROM_METADATA>"

install -d -m 0750 /root/pkg/node-runtime
curl -fsSL --cacert "${BOOTSTRAP_CACERT}" -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  "${RUNTIME_BUNDLE_URL}" -o /root/node-runtime.tgz
tar -xzf /root/node-runtime.tgz -C /root/pkg/node-runtime
dpkg -i /root/pkg/node-runtime/*.deb || true
DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/node-runtime --no-download -f install -y

install -d -m 0750 /etc/openvpn/client/pki

cat >/root/node-bundle-request.json <<EOF
{
  "node_id": "${NODE_ID}",
  "node_group": "${NODE_GROUP}",
  "role": "worker",
  "cluster": "${CLUSTER_NAME}",
  "metadata": {
    "instance_id": "${INSTANCE_ID}",
    "local_hostname": "${LOCAL_HOSTNAME}",
    "private_ip": "${PRIVATE_IP}"
  }
}
EOF

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_TOKEN_URL}" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -H "Content-Type: application/json" \
  --data @/root/node-bundle-request.json \
  -o /root/node-token-response.json

NODE_TOKEN="$(
  python3 - <<'PY' /root/node-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_BUNDLE_URL}" \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/root/node-bundle-request.json \
  -o /root/ovpn-node.tgz

tar -xzf /root/ovpn-node.tgz -C /etc/openvpn/client/pki
```

실환경 예시:

```bash
#!/bin/bash
set -euxo pipefail

ISSUER_TOKEN_URL="https://172.16.200.44:8443/v1/bootstrap/node-token"
ISSUER_BUNDLE_URL="https://172.16.200.44:8443/v1/bootstrap/node-bundle"
ISSUER_CACERT="/etc/ssl/certs/bootstrap-root-ca.pem"
NODE_ID="${NODE_ID_OVERRIDE:-$(hostname -s)}"
RUNTIME_BUNDLE_URL="https://172.16.200.44/ovpn/packages/node-runtime-ubuntu2204-amd64.tar.gz"
BOOTSTRAP_USER="bootstrap"
BOOTSTRAP_PASSWORD="tlsrlgh07"
BOOTSTRAP_CACERT="/etc/ssl/certs/bootstrap-root-ca.pem"
NODE_GROUP="default-worker"
CLUSTER_NAME="ta-sgh-pri-cls"
INSTANCE_ID="<INSTANCE_ID_FROM_METADATA>"
LOCAL_HOSTNAME="<LOCAL_HOSTNAME_FROM_METADATA>"
PRIVATE_IP="<PRIVATE_IP_FROM_METADATA>"

install -d -m 0750 /root/pkg/node-runtime
curl -fsSL --cacert "${BOOTSTRAP_CACERT}" -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  "${RUNTIME_BUNDLE_URL}" -o /root/node-runtime.tgz
tar -xzf /root/node-runtime.tgz -C /root/pkg/node-runtime
dpkg -i /root/pkg/node-runtime/*.deb || true
DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/node-runtime --no-download -f install -y

install -d -m 0750 /etc/openvpn/client/pki

cat >/root/node-bundle-request.json <<EOF
{
  "node_id": "${NODE_ID}",
  "node_group": "${NODE_GROUP}",
  "role": "worker",
  "cluster": "${CLUSTER_NAME}",
  "metadata": {
    "instance_id": "${INSTANCE_ID}",
    "local_hostname": "${LOCAL_HOSTNAME}",
    "private_ip": "${PRIVATE_IP}"
  }
}
EOF

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_TOKEN_URL}" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -H "Content-Type: application/json" \
  --data @/root/node-bundle-request.json \
  -o /root/node-token-response.json

NODE_TOKEN="$(
  python3 - <<'PY' /root/node-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_BUNDLE_URL}" \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/root/node-bundle-request.json \
  -o /root/ovpn-node.tgz

tar -xzf /root/ovpn-node.tgz -C /etc/openvpn/client/pki
```

이 방식은 기존 `정적 download endpoint` 대신 `Issuer API`가 발급과 응답을 직접 수행한다.

실환경 메모:

- 아래 내용은 현재 `ta-sgh-ca`에 실제 반영된 worker 자동발급 기준이다.
- `gateway VM`, `sidecar workload`는 같은 패턴으로 확장할 수 있지만, 현재 CA 서버에는 아직 worker endpoint만 실제 구현돼 있다.

현재 `ta-sgh-ca`에 반영한 `Issuer API`는 아래를 전제로 한다.

- endpoint: `https://172.16.200.44:8443`
- 서버 TLS: `/etc/nginx/tls/bootstrap.crt`, `/etc/nginx/tls/bootstrap.key`
- runtime 1회성 token 저장소: `/opt/ovpn-issuer/tokens.json`
- `node-token`은 `Basic Auth + metadata`를 검증하고 짧은 만료의 1회성 token을 발급한다.
- `node-bundle`은 그 1회성 token을 소모하면서 cert/bundle을 발급한다.

현재까지 실제 검증된 범위:

- `GET /healthz`
- `Basic Auth -> node-token -> node-bundle` 2단계 self-test 성공
- `EASYRSA_PASSIN` 설정 후 신규 cert 서명과 bundle 응답
- `NodeGroup-A` 새 worker scale-out 시 `node-token -> node-bundle -> OpenVPN 연결 -> split DNS` end-to-end 성공
- 같은 검증 흐름에서 `Private URI image pull -> test Pod 생성 -> pod curl https://www.google.com`까지 성공
- 발급된 1회성 token은 성공 후 `used=true`로 소모

아직 확장 전인 것:

- `/v1/bootstrap/gateway-token`, `/v1/bootstrap/gateway-bundle`의 실제 서버 구현
- `/v1/bootstrap/workload-token`, `/v1/bootstrap/workload-bundle`의 실제 서버 구현

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

직접 설치는 별도 아키텍처가 아니다. 현재 표준인 `7.5.1` 2차 스크립트가 하는 일을 특정 worker node에서 사람이 순서대로 수동 실행하는 방식으로 이해하면 된다.

즉 아래 절차는 다음 상황에서 쓴다.

- `NodeGroup-A` launcher 없이 특정 node 한 대만 수동 검증하고 싶을 때
- 장애 분석 중 `Issuer API`, `OpenVPN client`, `split DNS` 단계를 분리해서 보고 싶을 때
- 새 템플릿을 적용하기 전에 수동으로 먼저 끝까지 재현하고 싶을 때

템플릿:

```bash
BOOTSTRAP_IP="<BOOTSTRAP_IP>"
BOOTSTRAP_USER="<BOOTSTRAP_USER>"
BOOTSTRAP_PASSWORD="<BOOTSTRAP_PASSWORD>"
BOOTSTRAP_BASE_URL="https://${BOOTSTRAP_IP}/ovpn"
BOOTSTRAP_CA="/etc/ssl/certs/bootstrap-root-ca.pem"
ISSUER_TOKEN_URL="https://${BOOTSTRAP_IP}:8443/v1/bootstrap/node-token"
ISSUER_BUNDLE_URL="https://${BOOTSTRAP_IP}:8443/v1/bootstrap/node-bundle"

NODE_ID="$(hostname -s)"
NODE_GROUP="<NODE_GROUP>"
CLUSTER_NAME="<CLUSTER_NAME>"
NODE_ROLE="worker"
METADATA_INSTANCE_ID="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || hostname -s)"
METADATA_LOCAL_HOSTNAME="$(hostname -s)"
METADATA_PRIVATE_IP="$(hostname -I | awk '{print $1}')"

PRIVATE_VPC_NETWORK="<PRIVATE_VPC_NETWORK>"
PRIVATE_VPC_NETMASK="<PRIVATE_VPC_NETMASK>"
PUBLIC_VPC_NETWORK="<PUBLIC_VPC_NETWORK>"
PUBLIC_VPC_NETMASK="<PUBLIC_VPC_NETMASK>"
NKS_POD_NETWORK="<NKS_POD_NETWORK>"
NKS_POD_NETMASK="<NKS_POD_NETMASK>"
NKS_SERVICE_NETWORK="<NKS_SERVICE_NETWORK>"
NKS_SERVICE_NETMASK="<NKS_SERVICE_NETMASK>"
OPENVPN_SERVER_IP="<OPENVPN_SERVER_PRIVATE_IP>"
OPENVPN_SERVER_PORT="<OPENVPN_SERVER_PORT>"
OPENVPN_PROTO="<OPENVPN_PROTO>"
EGRESS_DNS_1="<APPROVED_DNS_1>"
EGRESS_DNS_2="<APPROVED_DNS_2>"
PRIVATE_DNS_SERVER="<PRIVATE_DNS_SERVER>"
RUNTIME_BUNDLE="node-runtime-ubuntu2204-amd64.tar.gz"

sudo install -d -m 0755 /opt/ovpn-bootstrap
sudo install -d -m 0755 /root/pkg/node-runtime
sudo install -d -m 0755 /etc/openvpn/client
sudo install -d -m 0700 /etc/openvpn/client/pki

curl -k -fsSL -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -o "${BOOTSTRAP_CA}" \
  "${BOOTSTRAP_BASE_URL}/packages/bootstrap-root-ca.pem"
sudo chmod 0644 "${BOOTSTRAP_CA}"

curl -fsSL --cacert "${BOOTSTRAP_CA}" -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -o /opt/ovpn-bootstrap/${RUNTIME_BUNDLE} \
  "${BOOTSTRAP_BASE_URL}/packages/${RUNTIME_BUNDLE}"

sudo tar xzf /opt/ovpn-bootstrap/${RUNTIME_BUNDLE} -C /root/pkg/node-runtime
sudo bash -lc 'dpkg -i /root/pkg/node-runtime/*.deb || true'
sudo bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/node-runtime --no-download -f install -y || true'

cat >/opt/ovpn-bootstrap/node-bundle-request.json <<EOF
{
  "node_id": "${NODE_ID}",
  "node_group": "${NODE_GROUP}",
  "role": "${NODE_ROLE}",
  "cluster": "${CLUSTER_NAME}",
  "metadata": {
    "instance_id": "${METADATA_INSTANCE_ID}",
    "local_hostname": "${METADATA_LOCAL_HOSTNAME}",
    "private_ip": "${METADATA_PRIVATE_IP}"
  }
}
EOF

curl -fsS --cacert "${BOOTSTRAP_CA}" -X POST "${ISSUER_TOKEN_URL}" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -H "Content-Type: application/json" \
  --data @/opt/ovpn-bootstrap/node-bundle-request.json \
  -o /opt/ovpn-bootstrap/node-token-response.json

NODE_TOKEN="$(
  python3 - <<'PY' /opt/ovpn-bootstrap/node-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['token'])
PY
)"

curl -fsS --cacert "${BOOTSTRAP_CA}" -X POST "${ISSUER_BUNDLE_URL}" \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/opt/ovpn-bootstrap/node-bundle-request.json \
  -o /opt/ovpn-bootstrap/${NODE_ID}.tar.gz

sudo tar xzf /opt/ovpn-bootstrap/${NODE_ID}.tar.gz -C /etc/openvpn/client/pki
sudo chmod 0644 /etc/openvpn/client/pki/ca.crt
sudo chmod 0644 /etc/openvpn/client/pki/client.crt
sudo chmod 0600 /etc/openvpn/client/pki/client.key
sudo chmod 0600 /etc/openvpn/client/pki/tls-crypt.key

sudo tee /etc/openvpn/client/worker-egress.conf >/dev/null <<EOF
client
dev tun
proto ${OPENVPN_PROTO}
remote ${OPENVPN_SERVER_IP} ${OPENVPN_SERVER_PORT}
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
route ${OPENVPN_SERVER_IP} 255.255.255.255 net_gateway
route ${PRIVATE_VPC_NETWORK} ${PRIVATE_VPC_NETMASK} net_gateway
route ${PUBLIC_VPC_NETWORK} ${PUBLIC_VPC_NETMASK} net_gateway
route ${NKS_POD_NETWORK} ${NKS_POD_NETMASK} net_gateway
route ${NKS_SERVICE_NETWORK} ${NKS_SERVICE_NETMASK} net_gateway
route 0.0.0.0 128.0.0.0 vpn_gateway
route 128.0.0.0 128.0.0.0 vpn_gateway
EOF

sudo systemctl enable --now openvpn-client@worker-egress

sudo resolvectl dns eth0 "${PRIVATE_DNS_SERVER}"
sudo resolvectl domain eth0 '~openstacklocal' '~container.nhncloud.com' '~nhncloudservice.com'
sudo resolvectl dns tun0 "${EGRESS_DNS_1}" "${EGRESS_DNS_2}"
sudo resolvectl domain tun0 '~.'
sudo resolvectl flush-caches
```

메모:

- 현재 `NKS worker 표준`을 그대로 재현하는 목적이면 `7.5.1`과 같은 `split DNS`까지 같이 적용한다.
- 단순히 `node curl google.com`만 확인하는 일반 OpenVPN client 검증이라면 `tun0` 쪽 DNS만으로도 충분할 수 있다.
- 하지만 현재 과업은 `Private URI image pull`, `test Pod 생성`, `pod curl https://www.google.com`까지 함께 보는 흐름이므로, 수동 설치도 결국 `7.5`와 같은 `split DNS` 기준으로 보는 편이 맞다.
- 실환경 값은 `7.5.2`의 `실환경 예시`와 동일한 값을 채우면 된다.

노드 egress 검증:

```bash
systemctl status openvpn-client@worker-egress --no-pager
ip addr show tun0
ip route
resolvectl status
resolvectl query www.google.com
curl -I https://www.google.com
curl https://ifconfig.me
```

판단 기준:

- `openvpn-client@worker-egress`가 `active (running)`이어야 한다.
- `tun0`에 `10.8.0.x/24`가 보여야 한다.
- `resolvectl query www.google.com`이 성공해야 `DNS uplink`도 같이 통과한 것으로 본다.
- `curl -I https://www.google.com`과 `curl https://ifconfig.me`가 성공하면 `node outbound`가 OpenVPN 경유로 나가는 상태로 본다.
- 이 단계가 끝난 뒤에만 `pod`에서 `nslookup google.com`, `curl -I https://www.google.com`을 본다.

### 7.7 검증

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

### 7.8 운영 팁

- 반드시 `전용 node group`으로 격리한다.
- cluster autoscaler를 쓴다면 신규 node도 같은 `node-token -> node-bundle` 규칙을 따라야 한다.
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
## 외부 다운로드 호스트
sudo apt-get update
sudo apt-get install -y apt-rdepends

mkdir -p pkg/gateway-runtime
cd pkg/gateway-runtime

apt-rdepends openvpn iptables-persistent 2>/dev/null \
  | grep -E '^[a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?$' \
  | sort -u > pkglist.raw

while read -r pkg; do
  if apt-cache show "$pkg" 2>/dev/null | grep -q '^Filename: '; then
    echo "$pkg"
  fi
done < pkglist.raw > pkglist.txt

xargs -a pkglist.txt sudo apt-get install --download-only --reinstall -y \
  -o Dir::Cache::archives="$(pwd)/"

tar czf ../gateway-runtime-ubuntu2204-amd64.tar.gz ./*.deb

## Gateway VM
sudo install -d -m 0750 /root/pkg/gateway-runtime
sudo tar xzf gateway-runtime-ubuntu2204-amd64.tar.gz -C /root/pkg/gateway-runtime
sudo bash -lc 'dpkg -i /root/pkg/gateway-runtime/*.deb || true'
sudo bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/gateway-runtime --no-download -f install -y'

sudo install -d -m 0750 /etc/openvpn/client/pki
```

Gateway VM bundle 수령 방식:

현재 worker와 동일한 `token -> bundle` 2단계 패턴을 gateway identity로 확장한 템플릿이다.

템플릿:

```bash
ISSUER_TOKEN_URL="https://<ISSUER_API_PRIVATE_IP>:8443/v1/bootstrap/gateway-token"
ISSUER_BUNDLE_URL="https://<ISSUER_API_PRIVATE_IP>:8443/v1/bootstrap/gateway-bundle"
ISSUER_CACERT="/etc/ssl/certs/bootstrap-root-ca.pem"
BOOTSTRAP_USER="<BOOTSTRAP_USER>"
BOOTSTRAP_PASSWORD="<BOOTSTRAP_PASSWORD>"
GATEWAY_ID="${GATEWAY_ID_OVERRIDE:-$(hostname -s)}"
GATEWAY_GROUP="<GATEWAY_GROUP>"
CLUSTER_NAME="<CLUSTER_NAME>"
INSTANCE_ID="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || hostname -s)"
LOCAL_HOSTNAME="$(hostname -s)"
PRIVATE_IP="$(hostname -I | awk '{print $1}')"

cat >/root/gateway-bundle-request.json <<EOF
{
  "gateway_id": "${GATEWAY_ID}",
  "gateway_group": "${GATEWAY_GROUP}",
  "role": "gateway",
  "cluster": "${CLUSTER_NAME}",
  "metadata": {
    "instance_id": "${INSTANCE_ID}",
    "local_hostname": "${LOCAL_HOSTNAME}",
    "private_ip": "${PRIVATE_IP}"
  }
}
EOF

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_TOKEN_URL}" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -H "Content-Type: application/json" \
  --data @/root/gateway-bundle-request.json \
  -o /root/gateway-token-response.json

GATEWAY_TOKEN="$(
  python3 - <<'PY' /root/gateway-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_BUNDLE_URL}" \
  -H "Authorization: Bearer ${GATEWAY_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/root/gateway-bundle-request.json \
  -o /root/${GATEWAY_ID}.tar.gz

sudo tar xzf /root/${GATEWAY_ID}.tar.gz -C /etc/openvpn/client/pki
```

PoC 또는 fallback 수동 방식:

```bash
sudo cp ~/dist/ovpn-gw-pri-01/* /etc/openvpn/client/pki/
sudo chmod 0644 /etc/openvpn/client/pki/ca.crt /etc/openvpn/client/pki/*.crt
sudo chmod 0600 /etc/openvpn/client/pki/*.key
```

메모:

- 현재 `ta-sgh-ca`에는 `worker node` endpoint만 실제 구현돼 있다.
- `gateway VM`에 full-auto를 적용하려면 위와 같은 요청 형식으로 `/v1/bootstrap/gateway-token`, `/v1/bootstrap/gateway-bundle`를 같은 패턴으로 추가하면 된다.
- 따라서 현재는 `템플릿`만 제공하고, `실환경 예시`는 아직 없다.

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
- gateway VM이 관리 대역, `CA / Bootstrap Server`, 내부 API와도 통신해야 한다면 해당 내부 대역은 `redirect-gateway def1`보다 우선하는 route로 남겨 둔다

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

메모:

- sidecar 이미지는 `NKS 내부`에서 빌드하는 것이 아니라, `인터넷이 되는 외부 빌드 환경` 또는 CI에서 빌드해 `내부 레지스트리`로 반입하는 전제를 둔다.
- 즉 이 `apt-get`은 `Pod 런타임`에서 실행되는 것이 아니라 `이미지 빌드 시점`에만 한 번 수행된다.
- `NodeGroup-C` worker는 `registry.internal`에 OpenVPN 수립 전에도 도달 가능해야 한다.
- 레지스트리가 인증을 요구하면 `imagePullSecrets`를 배포에 같이 넣는다.

`entrypoint.sh`

```bash
#!/bin/bash
set -euo pipefail
exec openvpn --config /etc/openvpn/client/client.conf
```

### 9.4 Kubernetes Secret

sidecar도 worker와 같은 `token -> bundle` 2단계 패턴으로 full-auto화할 수 있다. 다만 현재는 실제 구현 전이므로, 아래에는 fallback 수동 방식과 확장용 템플릿을 같이 둔다.

PoC 또는 fallback 수동 방식:

```bash
bash ~/easy-rsa/scripts/issue-client-bundle.sh ovpn-pod-ns1-app1-01 pod

kubectl -n app-ns create secret generic ovpn-client-bundle-app1 \
  --from-file=ca.crt="$HOME/dist/pods/ovpn-pod-ns1-app1-01/ca.crt" \
  --from-file=client.crt="$HOME/dist/pods/ovpn-pod-ns1-app1-01/client.crt" \
  --from-file=client.key="$HOME/dist/pods/ovpn-pod-ns1-app1-01/client.key" \
  --from-file=tls-crypt.key="$HOME/dist/pods/ovpn-pod-ns1-app1-01/tls-crypt.key"
```

템플릿:

```bash
ISSUER_TOKEN_URL="https://<ISSUER_API_PRIVATE_IP>:8443/v1/bootstrap/workload-token"
ISSUER_BUNDLE_URL="https://<ISSUER_API_PRIVATE_IP>:8443/v1/bootstrap/workload-bundle"
ISSUER_CACERT="/etc/ssl/certs/bootstrap-root-ca.pem"

cat >/tmp/workload-bundle-request.json <<'EOF'
{
  "namespace": "<APP_NAMESPACE>",
  "workload": "<WORKLOAD_NAME>",
  "type": "deployment",
  "bundle_scope": "workload",
  "cluster": "<CLUSTER_NAME>"
}
EOF

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_TOKEN_URL}" \
  -H "Authorization: Bearer <CI_OR_CONTROLLER_BOOTSTRAP_TOKEN>" \
  -H "Content-Type: application/json" \
  --data @/tmp/workload-bundle-request.json \
  -o /tmp/workload-token-response.json

WORKLOAD_TOKEN="$(
  python3 - <<'PY' /tmp/workload-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert "${ISSUER_CACERT}" -X POST "${ISSUER_BUNDLE_URL}" \
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

메모:

- `NKS Secure Key Manager` 연동을 쓰면 이 Secret은 `etcd 저장 시점`의 암호화에는 도움 된다.
- 하지만 sidecar가 mount 받은 뒤에는 일반 파일처럼 보이므로, runtime secret 노출면을 줄이려면 Pod 권한과 Secret 접근 범위를 별도로 통제해야 한다.
- 즉 `SKM`은 `OpenVPN CA` 대체재가 아니라 `Kubernetes Secret at-rest 보호` 수단으로 이해하는 편이 맞다.
- 현재 `ta-sgh-ca`에는 `workload` endpoint가 아직 실제 구현돼 있지 않다.
- sidecar full-auto를 쓰려면 위와 같은 2단계 흐름으로 `/v1/bootstrap/workload-token`, `/v1/bootstrap/workload-bundle`를 같은 패턴으로 추가하면 된다.
- sidecar는 Pod가 직접 발급 API를 두드리게 하기보다 `CI` 또는 `cluster 내부 controller`가 Secret을 갱신하는 편이 안전하다.
- 따라서 현재는 `템플릿`만 제공하고, `실환경 예시`는 아직 없다.

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
      imagePullSecrets:
        - name: regcred
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
          image: registry.internal/platform/openvpn-client:1.0.0
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
          image: registry.internal/base/curl:8.7.1
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
- 예시 이미지들은 모두 `내부 레지스트리에 미러링된 이미지`라는 전제를 둔다.

### 9.7 검증

```bash
kubectl -n app-ns exec -it deploy/app-with-ovpn -c vpn -- ip route
kubectl -n app-ns exec -it deploy/app-with-ovpn -c vpn -- ip addr show tun0
kubectl -n app-ns exec -it deploy/app-with-ovpn -c app -- curl -4 https://ifconfig.me
kubectl -n app-ns logs deploy/app-with-ovpn -c vpn
```
