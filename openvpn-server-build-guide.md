# OpenVPN Server 상세 구축 가이드

이 문서는 `Public VPC OpenVPN Server VM` 기준 상세 서버 구축 가이드다. 목적은 아래 두 가지다.

- `Private VPC NKS`의 client가 `OpenVPN Server`에 붙을 수 있게 한다
- 붙은 client의 외부 인터넷 통신을 `OpenVPN Server -> Internet Gateway`로 내보낸다

## 1. 적용 범위

- OS: `Ubuntu 22.04 LTS`
- OpenVPN: `OpenVPN OSS 2.6.x`
- 구성 위치: `Public VPC`의 `Public subnet`
- 접속 주체:
  - 주 방안의 `worker node OpenVPN client`
  - 추가 방안 1의 `VPN Gateway VM client`
  - 추가 방안 2의 `Pod sidecar OpenVPN client`

## 2. 명령 기준

이 문서의 패키지 설치 명령은 `apt`가 아니라 `apt-get` 기준이다.

이유:

- `apt`는 사람이 직접 쓰는 대화형 CLI에 가깝다
- `apt-get`은 스크립트/자동화에서 동작이 더 안정적이다
- `cloud-init`, `user script`, 운영 Runbook, Ansible shell task에는 `apt-get`이 일반적으로 더 적합하다

즉:

- 터미널에서 수동 실습: `apt`도 가능
- 문서/자동화/반복 작업: `apt-get` 권장

## 3. 서버 역할

OpenVPN Server VM은 아래 역할을 같이 수행한다.

- VPN 종단
- client 인증서 검증
- `tun0` 생성
- client 패킷 복호화
- 인터넷 outbound용 `IP forwarding`
- 외부 송신용 `SNAT/MASQUERADE`
- CRL 기반 폐기 인증서 차단

중요:

- 이 서버는 `HTTP Proxy`가 아니라 `VPN 서버 + egress NAT 장비`다
- `curl google.com`이 되려면 `OpenVPN 수립`만이 아니라 `forwarding + NAT + DNS`가 모두 맞아야 한다

## 4. 서버 배치 원칙

- OpenVPN Server는 `Public VPC`에 둔다
- client는 가능하면 `서버 public IP`가 아니라 `서버 private IP`로 붙는다
  - 전제: `Private VPC`와 `Public VPC`가 peering 연결되어 있어야 한다
- 서버는 인터넷 outbound가 가능해야 한다
- CA Server는 이 서버와 분리한다
  - 최소한 `CA private key`는 OpenVPN Server에 두지 않는다

## 5. 서버 파일 구조

권장 디렉터리:

```text
/etc/openvpn/server/
  server.conf
  pki/
    ca.crt
    ovpn-public-vpc-srv-01.crt
    ovpn-public-vpc-srv-01.key
    tls-crypt.key
    crl.pem
  ccd/   # 선택. client별 고정 정책이 필요할 때만

/var/log/openvpn/
  server.log
  openvpn-status.log
```

## 6. 서버 준비

### 6.1 패키지 설치

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  openvpn iptables-persistent ca-certificates
sudo install -d -m 0750 /etc/openvpn/server/pki
sudo install -d -m 0755 /var/log/openvpn
```

`/etc/openvpn/server/ccd`는 기본값으로 꼭 필요하지 않다. `CCD`를 실제로 쓸 때만 생성하면 된다.

메모:

- 기본 이미지에 `iptables` 명령 자체가 이미 들어 있는 경우가 많다.
- 여기서 `iptables-persistent`를 같이 설치하는 이유는 명령 제공보다 `재부팅 후 규칙 영속화`에 가깝다.
- 이미 `nftables`, `iptables-restore`, `cloud-init`, 별도 구성관리 도구로 규칙 영속화를 처리한다면 이 패키지는 생략할 수 있다.

### 6.2 번들 배치

```bash
sudo cp ~/dist/server/* /etc/openvpn/server/pki/
sudo chmod 0644 /etc/openvpn/server/pki/ca.crt
sudo chmod 0644 /etc/openvpn/server/pki/*.crt
sudo chmod 0644 /etc/openvpn/server/pki/crl.pem
sudo chmod 0600 /etc/openvpn/server/pki/*.key
```

검증:

```bash
sudo ls -l /etc/openvpn/server/pki
```

필수 파일:

- `ca.crt`
- `ovpn-public-vpc-srv-01.crt`
- `ovpn-public-vpc-srv-01.key`
- `tls-crypt.key`
- `crl.pem`

실무 메모:

- `crl.pem`은 비밀키가 아니라서 `0644`로 두는 편이 일반적이다.
- 이유는 OpenVPN 프로세스가 초기 바인딩 후 `user nobody`, `group nogroup`으로 권한을 낮춘 뒤에도 `crl.pem`을 읽을 수 있어야 하기 때문이다.
- 반대로 서버 개인키와 `tls-crypt.key`는 계속 `0600`으로 유지한다.

## 7. 커널 및 네트워크 준비

### 7.1 IP forwarding

`/etc/sysctl.d/99-openvpn.conf`

```conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
```

적용:

```bash
sudo sysctl --system
sysctl net.ipv4.ip_forward
sysctl net.ipv4.conf.all.rp_filter
```

정상 기대값:

```text
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
```

왜 `rp_filter=2`인가:

- OpenVPN 서버는 `tun0`와 `eth0` 사이를 라우팅하는 장비다
- 클라우드 NAT, peering, 터널 경유 환경에서는 응답 경로가 단순 단일 NIC 왕복이 아닐 수 있다
- Linux의 strict reverse path filtering(`1`)은 이런 패킷을 스푸핑으로 오인해 드롭할 수 있다
- 완전 비활성(`0`)보다 `loose mode(2)`가 실무적으로 균형이 좋다

### 7.2 인터넷 방향 NIC 확인

OpenVPN 서버에서 실제 인터넷 outbound가 나가는 NIC 이름을 먼저 확인한다.

```bash
ip route
ip -br addr
```

일반적으로 예시는 `eth0`를 쓰지만, 실제 NIC 이름은 환경에 맞게 바꿔야 한다.

실무 메모:

- Ubuntu 22.04에서도 `ens3`, `ens5`, `enp0s3`처럼 이름이 다를 수 있다
- `iptables`와 `sysctl` 예시는 반드시 실제 NIC 기준으로 치환한다
- 잘못된 NIC 이름을 쓰면 VPN은 붙는데 인터넷 outbound만 실패하는 일이 흔하다

### 7.3 주소 계획 원칙

OpenVPN 서버에서 가장 먼저 틀어지기 쉬운 것이 `터널 대역 설계`다.

원칙:

- `server <OPENVPN_TUNNEL_NETWORK> <OPENVPN_TUNNEL_NETMASK>` 대역은 아래와 겹치면 안 된다
  - `Private VPC CIDR`
  - `Public VPC CIDR`
  - `NKS Pod CIDR`
  - `NKS Service CIDR`
  - 온프레미스 또는 peering된 타 VPC 대역
- `topology subnet` 기준에서는 client 하나당 사실상 하나의 tunnel IP가 필요하다
- `ifconfig-pool-persist`를 쓰면 client와 IP 매핑을 추적하기 쉬워진다

설계 기준:

- PoC: `/24`로도 충분한 경우가 많다
- 운영: 예상 최대 client 수, 재접속 burst, 고정 IP 필요 여부를 같이 본다

예:

- worker node client가 30대
- gateway VM 2대
- sidecar workload 10개
- 여유 30%

이런 경우 `/24`는 충분하지만, 향후 확장성을 보면 `/23` 이상을 검토할 수 있다

## 8. server.conf 상세 예시

파일: `/etc/openvpn/server/server.conf`

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

### 8.1 주요 directive 설명

#### `port <OPENVPN_SERVER_PORT>`

- 역할:
  - OpenVPN 서버가 수신 대기할 L4 포트를 지정한다.
  - 이 값은 단순히 프로세스 바인딩 포트가 아니라 보안그룹, ACL, 방화벽, 운영 모니터링, 패킷 캡처 필터 기준이 되는 식별값이다.
- 현재 값 선택 이유:
  - 명시적으로 적어 두면 운영자가 `ss -lunp`, 보안정책, 외부 허용 정책을 같은 값으로 맞출 수 있다.
  - 기본 포트 `1194`를 그대로 쓰는 것도 가능하지만, 운영 문서에서는 “기본값에 의존하지 않는다”가 더 안전하다.
- 대안:
  - `1194/udp`는 가장 흔한 기본값이라 문서/예시가 많고 운영자 친화적이다.
  - 조직 정책상 특정 포트만 허용되면 그 포트로 바꿀 수 있다.
- 잘못 설정했을 때 증상:
  - 서버는 떠 있는데 client가 `TLS key negotiation failed`, `Connection timed out`처럼 보일 수 있다.
  - 특히 보안그룹은 열렸는데 `server.conf` 포트만 다르거나, 반대로 `server.conf`는 맞지만 ACL이 막혀 있는 경우가 흔하다.

#### `proto <OPENVPN_PROTO>`

- 역할:
  - OpenVPN 제어 채널과 데이터 채널이 어떤 전송 프로토콜 위에서 움직일지 결정한다.
  - 사실상 `UDP 기반 VPN`으로 볼지, `TCP 기반 VPN`으로 볼지를 정하는 핵심 옵션이다.
- 왜 일반적으로 `udp`인가:
  - VPN 터널 안에는 이미 TCP 애플리케이션이 많이 흐른다.
  - 그 위에 다시 TCP 터널을 씌우면 상위 TCP와 하위 TCP가 동시에 재전송/혼잡제어를 하면서 지연과 성능 저하가 커진다.
  - 이 문제가 흔히 말하는 `TCP over TCP meltdown`이다.
  - 따라서 일반 인터넷 egress, API 호출, 다수 세션 환경에서는 `UDP`가 보통 더 적합하다.
- 어떤 특수 상황에 `tcp`를 검토하나:
  - 중간 네트워크가 UDP를 막는 경우
  - 방화벽/프록시 정책상 TCP만 통과 가능한 경우
  - 패킷 손실보다 “무조건 통과”가 우선인 네트워크에서 우회 수단이 필요한 경우
- 잘못 설정했을 때 증상:
  - `tcp`를 써서 연결은 되지만 대량 응답이나 TLS 많은 워크로드에서 체감 성능이 급격히 떨어질 수 있다.
  - `udp`를 썼는데 중간망이 UDP를 막으면 아예 연결이 안 되거나 handshake 단계에서 끊긴다.

#### `dev tun`

- 역할:
  - OpenVPN이 생성할 가상 인터페이스 타입을 정한다.
  - `tun`은 L3(IP 패킷) 터널이고, `tap`은 L2(Ethernet 프레임) 브리지다.
- 현재 값 선택 이유:
  - 이번 과업은 `Pod/Node/Gateway의 아웃바운드 라우팅`이 핵심이다.
  - 즉 필요한 것은 L2 브리지가 아니라 “특정 IP 트래픽을 터널로 보낼 수 있는 라우팅 장치”다.
  - 그래서 `tap`보다 `tun`이 맞다.
- 대안:
  - `tap`은 브리지형 네트워크, 브로드캐스트/멀티캐스트 의존 환경, 레거시 L2 연동이 필요할 때 검토한다.
  - 하지만 클라우드 VPC, Kubernetes egress, 일반 API 호출 경로에는 보통 과하다.
- 잘못 설정했을 때 증상:
  - `tap`을 선택하면 불필요하게 설계가 복잡해지고, 클라우드 네트워크와의 궁합도 나빠질 수 있다.
  - 반대로 `tun`이 필요한 구조에서 `tap`을 쓰면 문제 해결이 아니라 문제 증식이 된다.

#### `topology subnet`

- 역할:
  - OpenVPN이 client 주소를 어떤 형태로 배정할지 정한다.
  - 현대 OpenVPN에서는 `subnet`이 사실상 기본 표준에 가깝다.
- 현재 값 선택 이유:
  - `subnet`은 client가 같은 논리 subnet 안에 있는 것처럼 주소를 사용하므로 구조가 직관적이다.
  - 구형 `net30`보다 이해하기 쉽고 라우팅형 환경에 더 잘 맞는다.
- 대안:
  - 아주 오래된 client 호환이 필요하면 `net30`을 볼 수 있지만, 현재 OpenVPN 2.6 계열 기준으로는 특별한 이유가 없다.
- 잘못 설정했을 때 증상:
  - topology와 `ccd`, `ifconfig-push`, 주소 계획이 맞지 않으면 특정 client만 이상한 IP를 받거나 route가 꼬일 수 있다.

#### `server <OPENVPN_TUNNEL_NETWORK> <OPENVPN_TUNNEL_NETMASK>`

- 역할:
  - OpenVPN 서버가 관리할 터널용 주소 풀을 정의한다.
  - 단순히 “네트워크 하나 잡는다”가 아니라 client IP pool, route 계산, NAT source CIDR, status 파일의 virtual address 기준이 된다.
- 현재 값 선택 이유:
  - 문서에서 별도 터널 대역을 분리한 이유는 VPC, Pod, Service, 온프레미스 대역과 겹치지 않게 하기 위해서다.
  - 이 값은 `iptables -t nat -A POSTROUTING -s <OPENVPN_TUNNEL_CIDR>`와 반드시 일관되어야 한다.
- 대안:
  - 더 작은 PoC면 `/24`, 더 큰 운영이면 `/23` 이상을 검토할 수 있다.
  - 핵심은 “여유”보다 “대역 충돌 회피”가 우선이다.
- 잘못 설정했을 때 증상:
  - 다른 내부 대역과 겹치면 연결은 붙는데 특정 목적지만 안 가거나, 응답이 엉뚱한 route로 빠지는 이상한 증상이 나온다.

#### `ca /etc/openvpn/server/pki/ca.crt`

- 역할:
  - 어떤 CA를 신뢰할지 정의한다.
  - 서버는 이 CA를 기준으로 client 인증서를 검증한다.
- 현재 값 선택 이유:
  - 이번 구성은 `Easy-RSA` 기반 자체 PKI를 전제로 한다.
  - 따라서 신뢰 anchor는 내부 CA 하나로 고정하는 편이 운영 추적이 쉽다.
- 대안:
  - 중간 CA 체인을 쓰는 구조라면 chain 파일 구성이 달라질 수 있다.
  - 하지만 공공기관/내부 통제형 구성에서는 내부 발급 CA 명시가 일반적이다.
- 잘못 설정했을 때 증상:
  - client는 cert가 멀쩡한데 서버가 `VERIFY ERROR`를 내며 붙지 않는다.
  - 특히 잘못된 CA 파일, 오래된 CA 파일, chain 누락이 흔한 원인이다.

#### `cert /etc/openvpn/server/pki/ovpn-public-vpc-srv-01.crt`

- 역할:
  - 서버 자신이 client에게 제시하는 서버 인증서다.
- 현재 값 선택 이유:
  - 서버 자산별 고유 인증서로 운영해야 교체, 추적, 사고 대응이 가능하다.
  - 문서의 `ovpn-public-vpc-srv-01`은 바로 그 “서버 개체 식별”을 의미한다.
- 대안:
  - 새 버전 교체 시 `ovpn-public-vpc-srv-01-2026q2`처럼 버전 suffix를 붙이는 전략이 운영상 유리하다.
- 잘못 설정했을 때 증상:
  - key와 짝이 안 맞거나, 목적이 server 용도가 아니면 TLS handshake 단계에서 실패한다.

#### `key /etc/openvpn/server/pki/ovpn-public-vpc-srv-01.key`

- 역할:
  - 서버 인증서의 개인키다.
- 현재 값 선택 이유:
  - 서버 cert와 1:1로 짝을 이루며 파일 권한은 반드시 더 엄격해야 한다.
- 대안:
  - 암호 걸린 key를 쓸 수는 있지만 무인 기동 자동화와 충돌하므로, 이번 과업에서는 무암호 key + 파일 권한 관리가 현실적이다.
- 잘못 설정했을 때 증상:
  - 인증서와 key가 mismatch면 서비스 자체가 안 뜨거나 TLS handshake에서 실패한다.
  - 권한이 너무 열려 있어도 보안상 치명적이다.

#### `crl-verify /etc/openvpn/server/pki/crl.pem`

- 역할:
  - 폐기된 인증서 목록(CRL)을 기준으로 client 접속을 차단한다.
- 현재 값 선택 이유:
  - 개체별 cert 운영을 하려면 폐기 기능이 반드시 있어야 한다.
  - 공공기관/감사 대응 기준에서는 사실상 필수다.
  - 이 파일은 OpenVPN이 권한 강등 이후에도 읽을 수 있어야 하므로, 운영에서는 보통 `0644`로 두고 소유자/배포 경로를 관리한다.
- 대안:
  - CRL 대신 아주 짧은 인증서 수명으로만 버티는 방식도 있지만, 유출/사고 대응 면에서 불충분하다.
- 잘못 설정했을 때 증상:
  - 유출된 cert가 계속 붙을 수 있다.
  - 반대로 손상된 CRL이나 권한 문제면 정상 client까지 다 차단될 수 있다.

#### `tls-crypt /etc/openvpn/server/pki/tls-crypt.key`

- 역할:
  - OpenVPN control channel에 대한 사전 공유 키 보호를 제공한다.
  - TLS 핸드셰이크 이전 단계부터 일부 메타데이터 보호와 노이즈 제거 효과가 있다.
- 현재 값 선택 이유:
  - `tls-auth`보다 메타데이터 은닉과 스캔 억제 측면에서 유리하다.
  - 인터넷에 노출되는 Public VPC 서버 기준으로 유용하다.
- 대안:
  - `tls-auth`는 더 단순하지만 `tls-crypt` 대비 은닉 수준이 낮다.
  - 아주 제한된 폐쇄망이면 굳이 둘 다 안 쓸 수도 있으나, 이 과업에는 맞지 않는다.
- 잘못 설정했을 때 증상:
  - key가 서버와 client에서 다르면 TLS negotiation 이전에 바로 실패한다.
  - 이 키는 서버와 모든 client가 공유하므로 유출 시 전면 재배포가 필요하다.

#### `verify-client-cert require`

- 역할:
  - client에게 반드시 인증서를 요구한다.
- 현재 값 선택 이유:
  - 이번 구성은 mTLS가 기본이다.
  - 따라서 “인증서 없는 client는 애초에 붙지 않는다”를 명시적으로 선언하는 편이 좋다.
- 대안:
  - `none` 또는 약한 인증과 결합하는 방식은 다른 인증 체계가 있을 때만 본다.
  - 하지만 그건 이번 과업의 보안 모델과 맞지 않는다.
- 잘못 설정했을 때 증상:
  - 인증서 없는 클라이언트 허용 같은 의도치 않은 약화가 생길 수 있다.

#### `remote-cert-tls client`

- 역할:
  - 상대방이 제시한 cert가 실제로 “client 용도”인지 확인한다.
- 현재 값 선택 이유:
  - 서버 cert를 client처럼 재사용하거나, 목적이 다른 cert를 오용하는 일을 줄인다.
  - PKI 운영을 엄격히 할수록 넣는 편이 맞다.
- 대안:
  - EKU 검증을 더 세밀하게 하려면 PKI 정책 자체를 강화해야 한다.
- 잘못 설정했을 때 증상:
  - 잘못된 용도의 cert를 그냥 통과시키는 PKI 구멍이 생길 수 있다.

#### `dh none`

- 역할:
  - 전통적인 static DH parameter 파일을 쓰지 않겠다는 선언이다.
- 현재 값 선택 이유:
  - OpenVPN 2.6 + ECDHE 기반에서는 별도 `dh.pem` 없이도 충분하다.
  - 관리 포인트를 줄이고 구식 DH parameter 관리 부담을 없앤다.
- 대안:
  - 구형 호환 환경이면 별도 DH 파일을 둘 수 있지만, 현재 문서 기준에선 필요성이 낮다.
- 잘못 설정했을 때 증상:
  - 구형 구성 문서를 그대로 따라 `dh` 파일을 섞어 쓰면 일관성이 깨질 수 있다.

#### `ecdh-curve prime256v1`

- 역할:
  - ECDHE에 사용할 곡선을 지정한다.
- 현재 값 선택 이유:
  - `prime256v1`는 호환성이 높고 널리 쓰이는 선택지다.
  - PoC와 운영 공통 분모로 무난하다.
- 대안:
  - 더 강한 곡선을 검토할 수 있지만, 모든 client 호환성과 운영 단순성까지 함께 봐야 한다.
- 잘못 설정했을 때 증상:
  - 일부 client와 핸드셰이크 호환성 문제가 생길 수 있다.

#### `tls-version-min 1.2`

- 역할:
  - 허용할 최소 TLS 버전을 제한한다.
- 현재 값 선택 이유:
  - TLS 1.0/1.1 같은 구버전을 배제하고 현재 기준의 최소 보안선으로 맞추기 위함이다.
- 대안:
  - 모든 client가 지원한다면 더 엄격하게 볼 수 있지만, OpenVPN/OpenSSL 조합 호환성을 같이 봐야 한다.
- 잘못 설정했을 때 증상:
  - 너무 높게 잡으면 구형 client가 접속하지 못하고, 너무 낮게 잡으면 불필요한 취약면이 열린다.

#### `data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305`

- 역할:
  - 데이터 채널에서 협상 가능한 cipher 목록과 우선순위를 지정한다.
- 현재 값 선택 이유:
  - AEAD 계열을 우선 사용해 성능과 보안 균형을 잡는다.
  - 목록 순서는 우선순위이며, 환경에 따라 CPU 가속 여부가 달라질 수 있다.
- 대안:
  - x86 AES-NI 환경이면 AES-GCM이 매우 유리할 수 있다.
  - 일부 ARM/저가상화 환경에서는 CHACHA20-POLY1305가 더 나을 수도 있다.
- 잘못 설정했을 때 증상:
  - client와 공통 cipher가 없으면 연결은 되는데 데이터 채널 협상에서 실패할 수 있다.
  - 너무 많은 구형 cipher를 열어두면 표면이 커진다.

#### `keepalive 10 60`

- 역할:
  - `ping 10`과 `ping-restart 60`의 축약형이다.
  - dead peer 감지와 세션 재수립 타이밍에 직접 관여한다.
- 현재 값 선택 이유:
  - 지나치게 공격적이지 않으면서도 세션 유실을 너무 늦게 감지하지 않는 무난한 출발점이다.
- 대안:
  - 지연이 큰 회선이면 더 느슨하게
  - 장애 감지가 아주 중요하면 더 짧게
  - 다만 값은 RTT, 손실률, 세션 수를 같이 보고 정해야 한다
- 잘못 설정했을 때 증상:
  - 너무 짧으면 정상 회선에서도 세션이 자주 끊긴다.
  - 너무 길면 장애를 늦게 감지해 failover와 운영 대응이 느려진다.

#### `persist-key`

- 역할:
  - 재기동이나 재접속 시 key 파일을 반복해서 다시 읽고 열지 않도록 한다.
- 현재 값 선택 이유:
  - 장기 실행 서비스에서 불필요한 재초기화를 줄인다.
- 대안:
  - 특별한 키 교체 실험 상황을 제외하면 보통 켜는 편이 낫다.
- 잘못 설정했을 때 증상:
  - 없다고 바로 장애가 나는 건 아니지만, 재시작 동작과 키 접근 흐름이 더 거칠어진다.

#### `persist-tun`

- 역할:
  - 재접속 시 TUN 인터페이스를 가능하면 유지한다.
- 현재 값 선택 이유:
  - 인터페이스 flap을 줄여 route/NAT/모니터링 변동성을 줄인다.
- 대안:
  - 인터페이스를 매번 깨끗하게 다시 만들고 싶은 특수한 디버깅 상황이 아니라면 유지가 일반적이다.
- 잘못 설정했을 때 증상:
  - 재접속 시 tun0가 매번 내려갔다 올라오며 route 변동과 짧은 끊김이 커질 수 있다.

#### `user nobody`

- 역할:
  - 초기 바인딩과 장치 생성 후 프로세스 권한을 낮춘다.
- 현재 값 선택 이유:
  - 루트 권한으로 계속 상주하는 범위를 줄여 위험을 낮춘다.
- 대안:
  - 전용 서비스 계정을 둘 수도 있다.
  - 보안 기준이 높으면 `nobody`보다 명시적 전용 계정을 더 선호하기도 한다.
- 잘못 설정했을 때 증상:
  - 너무 제한적인 계정으로 내리면 로그 파일, 상태 파일, 장치 접근에서 권한 오류가 날 수 있다.

#### `group nogroup`

- 역할:
  - 위 `user`와 같은 취지로 그룹 권한도 낮춘다.
- 현재 값 선택 이유:
  - Ubuntu 계열에서 무난한 기본값이다.
- 대안:
  - 전용 그룹을 운영 기준에 맞게 만들 수도 있다.
- 잘못 설정했을 때 증상:
  - 파일/로그 권한 불일치가 발생할 수 있다.

#### `status /var/log/openvpn/openvpn-status.log`

- 역할:
  - 현재 세션 상태를 주기적으로 기록하는 상태 파일 경로다.
- 현재 값 선택 이유:
  - `journalctl`만으로는 세션 전반을 한눈에 보기 어렵다.
  - 어떤 CN이 어떤 virtual IP로 붙어 있는지 보려면 status 파일이 유용하다.
- 대안:
  - 경로는 바꿀 수 있지만 운영팀이 바로 찾기 쉬운 위치가 좋다.
- 잘못 설정했을 때 증상:
  - 권한/경로 오류면 상태 파일이 안 생기고, 운영자가 세션 상태를 잘못 판단할 수 있다.

#### `log-append /var/log/openvpn/server.log`

- 역할:
  - OpenVPN 로그를 지정 파일에 누적 기록한다.
- 현재 값 선택 이유:
  - `log`와 달리 재기동 때 덮어쓰지 않고 이어 붙인다.
  - 장기 장애 분석과 이력 추적에 더 유리하다.
- 대안:
  - journald만 쓸 수도 있지만, 파일 로그를 병행하면 추출/백업이 쉬운 경우가 많다.
- 잘못 설정했을 때 증상:
  - 파일이 커질 수 있으므로 `logrotate`를 같이 안 잡으면 디스크를 압박할 수 있다.

#### `verb 3`

- 역할:
  - OpenVPN 로그 상세도를 제어한다.
  - 값이 낮을수록 조용하고, 높을수록 세부 이벤트를 더 많이 출력한다.
- 현재 값 선택 이유:
  - `verb 3`은 운영 상시값으로 많이 쓰는 절충점이다.
  - 연결 상태, 기본적인 TLS/route 문제는 보이되, 패킷 수준에 가까운 과다 로그는 피한다.
- 대안:
  - `verb 1~2`: 아주 조용하지만 정보 부족
  - `verb 4~6`: 장애 분석에는 유용하지만 운영 상시 로그로는 과한 편
  - 더 높으면 디버깅 전용에 가깝다
- 잘못 설정했을 때 증상:
  - 너무 낮으면 원인 파악이 어렵다.
  - 너무 높으면 로그 폭증, 분석 피로도 증가, 디스크 사용량 증가가 생긴다.

### 8.2 이 server.conf에서 의도적으로 넣지 않은 값

아래는 실무에서 많이 보이지만, 이번 구성에서는 기본값으로 넣지 않은 것들이다.

- `duplicate-cn`
  - 왜 넣지 않나:
    - 하나의 인증서를 여러 client가 동시에 공유해도 접속을 허용하는 옵션이다.
    - 이 값을 켜면 `누가 어떤 세션을 만들었는지`를 CN 기준으로 식별하기 어려워진다.
    - 특정 node 또는 특정 workload만 폐기하고 싶어도, 같은 cert를 공유한 나머지까지 같이 갈아야 한다.
  - 이번 과업과 충돌하는 이유:
    - 문서 전체가 `node별`, `gateway별`, `workload별` 개체 식별과 폐기를 전제로 한다.
    - 공공기관/감사 대응에서는 추적성과 개체별 폐기성이 중요하다.
  - 언제만 예외인가:
    - 아주 짧은 PoC에서 공용 인증서 하나로 빨리 붙여보는 임시 테스트 정도는 가능하다.
    - 하지만 운영 기준 문서의 기본값으로 둘 성격은 아니다.
- `client-to-client`
  - 왜 넣지 않나:
    - 이 옵션은 VPN에 붙은 client끼리 서버 내부에서 직접 통신하도록 허용한다.
    - 즉 VPN 서버가 단순 `egress 종단`이 아니라 client 간 동서 통신 허브가 된다.
  - 이번 과업과 충돌하는 이유:
    - 목표는 `Pod/Node/Gateway -> 외부 인터넷/API` 경로다.
    - client끼리 서로 볼 필요가 없고, 오히려 불필요한 lateral movement 경로가 생긴다.
  - 언제만 예외인가:
    - VPN client끼리 실제로 상호 서비스 접근이 필요한 구조에서만 검토한다.
    - 이번 과업의 기본 서버 설정에는 맞지 않는다.
- `push "redirect-gateway def1"`
  - 왜 넣지 않나:
    - 이 옵션은 client의 기본 경로를 서버가 강제로 VPN 쪽으로 돌린다.
    - 편해 보이지만, client마다 남겨야 할 내부 대역이 다른 순간부터 통제가 어려워진다.
  - 이번 과업과 충돌하는 이유:
    - `worker node`, `VPN Gateway VM`, `sidecar`는 각각 bypass route 요구가 다르다.
    - 서버가 공통 push로 기본 경로를 덮어쓰면 내부망, Pod/Service CIDR, API server, DNS 경로를 망가뜨릴 위험이 커진다.
  - 언제만 예외인가:
    - 모든 client의 성격이 같고, 남겨야 할 내부 대역도 동일하며, 서버가 중앙에서 일괄 통제하는 구조일 때만 검토한다.
    - 지금처럼 역할이 섞인 구조에서는 기본값으로 두지 않는 편이 맞다.
- `push "dhcp-option DNS ..."`
  - 왜 넣지 않나:
    - 이 옵션은 client의 DNS resolver 선택에 직접 영향을 준다.
    - 단순한 VM client만 있는 환경에서는 유용할 수 있지만, Kubernetes와 섞이면 훨씬 복잡해진다.
  - 이번 과업과 충돌하는 이유:
    - `ClusterFirst`, `CoreDNS`, `NodeLocal DNS`, sidecar 실험용 `dnsPolicy: None`이 함께 존재할 수 있다.
    - 서버가 DNS를 공통 push하면, “어떤 경로로 DNS가 나가야 하는지”를 client가 아니라 서버가 강제로 결정하게 된다.
    - 그 결과 `google.com`은 되는데 cluster DNS가 깨지거나, 반대로 cluster DNS는 되는데 외부 이름 해석이 꼬일 수 있다.
  - 언제만 예외인가:
    - 모든 client가 단순 리눅스 VM이고, 공통 DNS를 강제해야 하며, Kubernetes DNS 경로와 충돌하지 않을 때만 고려한다.
- `client-config-dir /etc/openvpn/server/ccd`
  - 왜 넣지 않나:
    - CCD는 강력하지만, 서버 쪽에서 client별 예외 정책을 계속 관리하게 만든다.
    - route, 고정 IP, push 정책이 client 수만큼 분기되기 시작하면 운영 복잡도가 빠르게 커진다.
  - 이번 과업과 충돌하는 이유:
    - 현재 설계는 “역할별 공통은 문서화된 client config로, 예외만 개별 처리”가 기본이다.
    - 그래서 기본 `server.conf`는 최대한 공통값만 두고, CCD는 정말 필요한 경우에만 여는 편이 더 단순하다.
  - 언제만 예외인가:
    - 특정 gateway에 고정 tunnel IP를 줘야 하거나, 특정 client만 별도 route/push가 꼭 필요할 때
    - 예: `/etc/openvpn/server/ccd/ovpn-gw-pri-01`
- `ifconfig-pool-persist /var/log/openvpn/ipp.txt`
  - 왜 넣지 않나:
    - 이 옵션은 상태 추적과 재현성을 높이는 운영 편의 기능이지, 연결 성립 자체의 필수 조건은 아니다.
  - 이번 과업과의 관계:
    - 지금 우선 목표는 `Pod에서 curl google.com`이 되는지와 각 방안의 원리 검증이다.
    - 따라서 기본 예시를 lean하게 유지하려면 빼는 편이 맞다.
  - 언제 다시 넣나:
    - client와 tunnel IP 매핑을 장기 추적해야 할 때
    - status 수집과 함께 운영 분석 자동화를 붙일 때
- `status-version 3`
  - 왜 넣지 않나:
    - status 파일을 사람이 직접 보는 수준이면 형식 버전까지 명시할 필요가 크지 않다.
    - 이 값은 주로 외부 수집기나 파서가 붙을 때 의미가 커진다.
  - 언제 다시 넣나:
    - 세션 상태를 정기 수집하거나, 상태 파일을 후처리하는 자동화가 붙을 때
- `data-ciphers-fallback AES-256-CBC`
  - 왜 넣지 않나:
    - fallback을 둔다는 것은 결국 “구버전 cipher까지 열어두겠다”는 뜻이다.
    - 호환성 면에서는 편하지만, 표면을 넓히고 설정 판단도 복잡하게 만든다.
  - 이번 과업과 충돌하는 이유:
    - 문서의 전제는 `OpenVPN 2.6.x`다.
    - 이 전제라면 AEAD cipher(`AES-GCM`, `CHACHA20-POLY1305`)만으로 시작하는 것이 더 일관되고 단순하다.
  - 언제만 예외인가:
    - 실제 client 중 일부가 2.6 미만이라 AEAD만으로는 붙지 않는 것이 확인됐을 때
    - 그때도 “정말 필요한 client가 있는가”를 먼저 검증한 뒤 추가하는 편이 맞다.
- `auth SHA256`
  - 왜 넣지 않나:
    - AEAD cipher만 쓸 때는 별도 HMAC auth 설정의 의미가 작아진다.
    - 이 옵션이 의미를 크게 가지는 건 CBC fallback 같은 non-AEAD 경로를 열었을 때다.
  - 이번 과업과의 관계:
    - 기본 conf를 AEAD 중심으로 단순화했기 때문에 같이 뺐다.
  - 언제 다시 넣나:
    - `data-ciphers-fallback`을 다시 열고 CBC 계열 호환을 유지해야 할 때
- `explicit-exit-notify 1`
  - 왜 넣지 않나:
    - UDP 환경에서 종료를 조금 더 깔끔하게 알리는 보조 옵션이지, 연결 성립의 핵심은 아니다.
    - 기본 예시를 lean하게 유지하려면 우선순위가 낮다.
  - 언제 다시 넣나:
    - 종료 감지와 세션 정리 품질을 조금 더 높이고 싶을 때
    - 특히 운영 중 세션 종료 이벤트를 더 명확히 보고 싶을 때
- `compress` / `comp-lzo`
  - 왜 쓰지 않나:
    - 압축은 “대역폭을 줄일 수 있다”는 장점이 있어 보이지만, 오늘날 일반 API/HTTPS 트래픽은 이미 상위 계층에서 압축되었거나 압축 효율이 낮은 경우가 많다.
    - 즉 기대만큼 실효성이 크지 않은 반면, 복잡성과 위험은 확실히 늘어난다.
  - 보안성 측면에서 왜 손해가 큰가:
    - 암호화 전 압축은 트래픽 길이 변화를 정보 누출 신호로 만들 수 있다.
    - TLS 계열에서 알려진 CRIME/BREACH/VORACLE류 문제의 핵심도 “압축 + 암호화된 길이 정보” 조합이다.
    - OpenVPN의 압축도 이런 류의 부채를 떠안을 수 있어, 현대 운영에서는 기본적으로 끄는 쪽이 맞다.
  - 상호운용성 측면에서 왜 손해가 큰가:
    - 서버와 client의 압축 옵션 조합이 어긋나면 연결이 안 되거나 예측하기 어려운 동작을 만든다.
    - 구형 `comp-lzo`, 신형 `compress`, 버전별 정책 차이가 섞이면 장애 분석이 어려워진다.
    - 특히 “어떤 client만 된다/안 된다” 문제를 만들기 쉽다.
  - 성능 측면에서도 왜 애매한가:
    - CPU를 더 쓰고, 이미 압축된 HTTPS/JSON/gzip 응답에는 이득이 거의 없을 수 있다.
    - 클라우드 VM에서 병목은 대역폭보다 CPU/conntrack/NAT에서 먼저 나는 경우가 많다.
  - 결론:
    - 특별한 이유가 없는 한 기본값으로 넣지 않는다.
    - 실제로 압축 이득이 큰 특수 트래픽이 있고, 보안/호환성 리스크를 감수할 근거가 있을 때만 별도 검토한다.
- `auth-user-pass-verify`
  - 왜 쓰지 않나:
    - 이 옵션은 사용자명/비밀번호 기반 인증 흐름을 서버에 추가하는 것이다.
    - 지금 문서의 기본 보안 모델은 `개체별 인증서 기반 mTLS`다.
  - 이번 과업과 충돌하는 이유:
    - node, gateway, sidecar workload는 “사람 사용자”가 아니라 시스템 개체다.
    - 이런 대상에 user/pass를 더하는 것은 secret 관리만 복잡하게 만들고, 인증 주체 모델도 흐려진다.
  - 언제만 예외인가:
    - 사람 사용자가 직접 VPN에 붙는 원격접속 VPN 같은 다른 제품 성격에서나 의미가 있다.
    - 지금의 시스템 간 egress VPN 기본값에는 맞지 않는다.

### 8.3 UDP와 TCP 선택 기준

실무적으로는 `UDP 우선`이 기본이다.

`UDP`가 맞는 경우:

- 일반적인 인터넷 outbound
- 지연과 재전송 오버헤드를 줄이고 싶을 때
- 터널 안에서 이미 TCP 애플리케이션이 많이 흐를 때

`TCP`를 검토하는 경우:

- 중간 방화벽/프록시가 UDP를 막는 경우
- 네트워크 정책상 TCP만 통과 가능한 경우

주의:

- OpenVPN over TCP 위에 다시 HTTPS/TCP가 올라가면 `TCP over TCP meltdown`로 성능이 크게 나빠질 수 있다
- 특별한 이유가 없으면 서버 기본값은 `UDP`가 맞다

### 8.4 왜 `redirect-gateway`를 서버에서 push하지 않나

이 문서의 기준에서는 `redirect-gateway def1`를 서버에서 일괄 push하지 않는다.

이유:

- 주 방안, 추가 방안 1, 추가 방안 2는 bypass route 요구가 서로 다르다
- `worker node`, `gateway VM`, `sidecar`가 내부망으로 남겨야 할 대역이 다를 수 있다
- 서버에서 일괄 push하면 내부 통신 장애 범위가 커진다

따라서 기본 방향은:

- 서버는 `터널 종단 + 세션 관리`
- client는 `자기 역할에 맞는 route 제어`

### 8.5 TLS/PKI 관점에서 꼭 이해해야 할 점

- 서버 cert와 client cert는 목적이 다르다
  - 서버 cert는 server 용도
  - client cert는 client 용도
- `remote-cert-tls client`를 server에 넣는 이유는 client cert 오용을 줄이기 위해서다
- `crl.pem`은 정적 파일이 아니라 운영 중 계속 바뀔 수 있는 자산이다
  - revoke 이후 배포가 늦으면 이미 폐기된 client가 계속 붙을 수 있다
- `tls-crypt.key`는 CA와는 다른 종류의 공유 키다
  - cert처럼 개체별이 아니라 서버와 모든 client가 공유한다
  - 그래서 배포와 회전 절차를 별도로 가져가야 한다

### 8.6 세션/성능 관점에서 꼭 이해해야 할 점

- `keepalive 10 60`은 무난한 출발점이지 절대값이 아니다
- 인터넷 품질이 나쁘면 `ping-restart`가 너무 짧아 오탐으로 세션이 재수립될 수 있다
- OpenVPN 서버 CPU 병목은 보통 아래에서 먼저 난다
  - TLS handshake burst
  - 대량의 암복호화
  - NAT/conntrack
- sidecar/client 수가 늘어나면 `세션 수` 자체를 capacity 항목으로 봐야 한다

MTU/MSS:

- 증상이 `연결은 되는데 큰 응답만 실패`라면 MTU/MSS를 먼저 의심한다
- 무조건 `fragment`를 켜기보다 먼저 경로 MTU와 SYN MSS를 본다
- 필요 시 client/server 양쪽에서 `mssfix`를 검토하되, 임의값을 먼저 박기보다 패킷 캡처로 확인하는 편이 낫다

## 9. 선택적 서버 측 push 설정

정말 서버에서 일부 공통 옵션을 push해야 한다면 아래처럼 최소한으로 사용한다.

예시:

```conf
push "ping 10"
push "ping-restart 60"
```

주의:

- `push "redirect-gateway def1"`는 지금 과업에서는 기본값으로 두지 않는다
- `push "dhcp-option DNS ..."`도 모든 client 유형에 맞는지 검증한 뒤에만 넣는다

실무 원칙:

- 서버 push는 `모든 client에 공통으로 안전한 값`만 쓴다
- 역할별 차이가 큰 값은 client config나 CCD로 내린다

## 10. CCD(client-config-dir) 사용 예시

`CCD`는 `client-config-dir` 아래에 두는 `클라이언트별 개별 설정 파일`이다.

의미:

- 파일 하나가 특정 client 한 개를 대표한다
- 보통 파일명은 `클라이언트 인증서 CN`과 정확히 같아야 한다
- 서버 공통 설정으로 넣기 애매한 `고정 IP`, `특정 route push`, `예외 정책`을 client별로 분기할 때 쓴다

이번 과업에서는 기본값으로 필요하지 않다.

이유:

- worker, gateway, sidecar의 기본 route 정책은 `client config` 쪽에서 제어하기로 했기 때문이다
- 따라서 `server.conf` 기본 예시에는 넣지 않고, `예외적인 고정 정책이 필요할 때만` 쓴다

특정 client에만 별도 정책을 줄 때는 `CCD`를 쓴다.

예시 파일:

`/etc/openvpn/server/ccd/ovpn-gw-pri-01`

```conf
# 예시: gateway client에 고정 tunnel IP를 주고 싶을 때
ifconfig-push <CCD_CLIENT_IP> <CCD_CLIENT_NETMASK>
```

메모:

- 실제로 `ifconfig-push`를 쓰려면 OpenVPN topology와 주소 계획이 정리돼 있어야 한다
- PoC에서는 동적 할당으로 시작하고, 운영형으로 갈 때 고정값을 검토해도 늦지 않다
- `ccd`는 강력하지만, 잘못 쓰면 route 충돌과 운영 복잡도를 같이 가져온다
- 이번 과업처럼 client 역할이 여러 종류면 `CCD는 예외적인 고정 정책`에만 쓰는 편이 안정적이다

## 11. NAT 및 FORWARD 설정

예시:

```bash
sudo iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s <OPENVPN_TUNNEL_CIDR> -o eth0 -j MASQUERADE
sudo netfilter-persistent save
```

설명:

- 첫 번째 규칙: VPN client -> 인터넷 방향 허용
- 두 번째 규칙: 응답 패킷 허용
- 세 번째 규칙: 인터넷 outbound 시 서버 NIC IP로 SNAT

중요:

- `eth0`는 실제 인터넷 방향 NIC로 치환한다
- `OPENVPN_TUNNEL_CIDR`은 `server.conf`의 터널 대역과 맞아야 한다
- FORWARD 기본 정책이 DROP이면 위 규칙이 더 중요하다
- Ubuntu 22.04의 `iptables`는 내부적으로 `nft` backend일 수 있다
- 운영 중 다른 자동화 도구가 방화벽 규칙을 덮어쓰지 않는지 확인해야 한다

실무 메모:

- OpenVPN 서버가 단순 tunnel 종단만이 아니라 `라우터/NAT 장비`라는 점을 잊으면 안 된다
- VPN 연결 성공과 인터넷 송신 성공은 별개다
- 실제 장애의 절반 이상은 OpenVPN 프로세스보다 NAT/FORWARD에서 난다

검증:

```bash
sudo iptables -S
sudo iptables -t nat -S
sudo iptables -V
```

## 12. 서비스 시작

```bash
sudo systemctl enable --now openvpn-server@server
sudo systemctl status openvpn-server@server --no-pager
```

실패 시 먼저 보는 항목:

- cert/key 파일 권한
- `crl.pem` 존재 여부
- 포트 충돌
- `server` 대역 중복
- `tls-crypt.key` 불일치
- systemd unit 이름과 conf 파일 경로 불일치

OpenVPN 2.x 계열에서 자주 놓치는 점:

- Debian/Ubuntu의 `openvpn-server@server`는 `/etc/openvpn/server/server.conf`를 읽는다
- 파일명과 unit 인스턴스명이 다르면 `기동은 했는데 다른 conf를 읽는` 일이 생길 수 있다

## 13. 서버 검증

### 13.1 서버 자체

```bash
sudo ss -lunp | grep <OPENVPN_SERVER_PORT>
ip addr show tun0
sudo journalctl -u openvpn-server@server -n 100 --no-pager
sudo tail -n 50 /var/log/openvpn/server.log
```

### 13.2 client 접속 후

```bash
sudo cat /var/log/openvpn/openvpn-status.log
```

여기서 확인할 것:

- 연결된 client CN
- virtual address
- 접속 시간
- 마지막 수신 시간

추가로 보면 좋은 것:

- 특정 client가 계속 재접속하는지
- 같은 CN이 여러 세션으로 보이는지
- gateway client와 node client가 예상한 CN 규칙대로 붙는지

## 14. DNS 관점에서 서버가 해야 할 일

OpenVPN 서버는 기본적으로 DNS 서버가 아니다. 하지만 client가 외부 DNS에 닿을 수 있게 해야 한다.

즉 서버 입장에서는 아래가 맞아야 한다.

- `tun0 -> eth0` forwarding 가능
- 외부 DNS 서버로 outbound 가능
- SNAT 정상 동작

중요한 구분:

- OpenVPN 서버가 DNS 서버 역할을 해야 하는 것은 아니다
- 하지만 DNS 패킷이 터널을 통해 나갈 수 있는 경로를 제공해야 한다
- `push "dhcp-option DNS ..."`를 서버에 넣는 순간, DNS 설계는 client와 CoreDNS 동작까지 포함한 문제로 커진다

지금 과업에서는 DNS를 서버에서 직접 해결하기보다, client 또는 CoreDNS upstream 설계에서 푸는 쪽이 단순하다.

## 15. 보안/운영 하드닝

- `CA private key`는 서버에 두지 않는다
- 서버 cert/key와 `tls-crypt.key` 파일 권한을 `0600`으로 유지한다
- `crl.pem` 갱신 절차를 운영 문서에 포함한다
- 보안그룹은 OpenVPN 포트와 필요한 운영 접근만 허용한다
- 로그 보존 기간과 용량을 정한다
- `duplicate-cn`은 허용하지 않는다
- `compress` 계열 옵션은 쓰지 않는다
- `client-to-client`는 특별한 필요가 없으면 열지 않는다
- `verb`를 상시 높이지 않는다
- 장기 운영이면 `logrotate` 또는 journald 정책을 같이 설계한다

logrotate 예시:

```conf
/var/log/openvpn/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
```

## 16. 장애 포인트

- OpenVPN 서버 프로세스 다운
- `tun0` 미생성
- NAT 규칙 유실
- `crl.pem` 손상 또는 권한 오류
- 서버의 인터넷 outbound 차단
- client가 서버 endpoint를 터널 쪽으로 잘못 보내는 라우팅 루프
- strict `rp_filter`로 인한 패킷 드롭
- 잘못된 `data-ciphers` 또는 `tls-crypt.key` 불일치
- DNS는 되는데 HTTP만 안 되는 경우와 HTTP는 되는데 DNS만 안 되는 경우를 혼동하는 것

## 17. 지금 과업 기준 최소 성공 조건

아래가 모두 맞아야 `Pod에서 curl google.com`이 성공한다.

- `Private VPC`와 `Public VPC` 간 peering 정상
- client가 `OpenVPN Server private IP`로 접속 가능
- 서버 `tun0` 생성
- 서버 `IP forwarding=1`
- 서버 `rp_filter=2`
- 서버 `FORWARD/NAT` 정상
- client 쪽 bypass route 정상
- DNS 이름 해석 정상

## 18. 다음 단계

이 문서는 서버 설계/구축 기준 문서다. 실제 적용용 파일이 더 필요하면 다음을 별도로 만들면 된다.

- 실제 값이 들어간 `server.conf`
- `iptables-restore` 파일
- `sysctl.d` 파일
- `systemd override`
