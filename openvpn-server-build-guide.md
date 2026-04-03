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
  ccd/

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
sudo install -d -m 0750 /etc/openvpn/server/ccd
sudo install -d -m 0755 /var/log/openvpn
```

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

## 7. 커널 및 네트워크 준비

### 7.1 IP forwarding

`/etc/sysctl.d/99-openvpn.conf`

```conf
net.ipv4.ip_forward=1
```

적용:

```bash
sudo sysctl --system
sysctl net.ipv4.ip_forward
```

정상 기대값:

```text
net.ipv4.ip_forward = 1
```

### 7.2 인터넷 방향 NIC 확인

OpenVPN 서버에서 실제 인터넷 outbound가 나가는 NIC 이름을 먼저 확인한다.

```bash
ip route
ip -br addr
```

일반적으로 예시는 `eth0`를 쓰지만, 실제 NIC 이름은 환경에 맞게 바꿔야 한다.

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
ifconfig-pool-persist /var/log/openvpn/ipp.txt
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/server.log
verb 3
explicit-exit-notify 1
```

### 8.1 주요 directive 설명

- `port`
  - OpenVPN 서버 수신 포트다
  - 보안그룹/ACL도 같은 포트를 열어야 한다
- `proto`
  - 일반적으로 `udp`를 우선 검토한다
  - 특수 환경에서만 `tcp`를 고려한다
- `dev tun`
  - L3 터널 장치다
  - 지금 요구사항은 브리지가 아니라 라우팅 구조라 `tap`보다 `tun`이 맞다
- `topology subnet`
  - client에게 서브넷 방식 주소 할당을 사용한다
- `server`
  - OpenVPN 터널용 주소 대역을 의미한다
  - VPC CIDR, Pod CIDR, Service CIDR과 겹치면 안 된다
- `ca`, `cert`, `key`
  - 서버 인증과 client 검증에 필요한 PKI 파일 경로다
- `crl-verify`
  - 폐기된 client 인증서를 차단한다
  - 공공기관/운영 환경에서는 사실상 필수다
- `tls-crypt`
  - control channel 보호용 키다
  - 무차별 스캔 및 일부 노이즈를 줄이는 데 도움이 된다
- `dh none`, `ecdh-curve prime256v1`
  - OpenVPN 2.6 기준 ECDHE 방식 사용 예시다
- `data-ciphers`
  - 허용할 데이터 채널 cipher 목록이다
- `keepalive`
  - 세션 유지 및 dead peer 감지 주기다
- `user`, `group`
  - 초기 바인딩 이후 낮은 권한으로 동작시킨다
- `client-config-dir`
  - client별 고정 route/push가 필요할 때 쓰는 디렉터리다
  - 지금 문서 기본값은 client 쪽 route 제어를 우선한다
- `ifconfig-pool-persist`
  - client별 할당 주소를 기록한다
  - 장애 분석 시 유용하다
- `status`, `log-append`
  - 세션 상태와 로그 파일이다
- `verb 3`
  - PoC/운영 공통으로 무난한 수준이다

### 8.2 왜 `redirect-gateway`를 서버에서 push하지 않나

이 문서의 기준에서는 `redirect-gateway def1`를 서버에서 일괄 push하지 않는다.

이유:

- 주 방안, 추가 방안 1, 추가 방안 2는 bypass route 요구가 서로 다르다
- `worker node`, `gateway VM`, `sidecar`가 내부망으로 남겨야 할 대역이 다를 수 있다
- 서버에서 일괄 push하면 내부 통신 장애 범위가 커진다

따라서 기본 방향은:

- 서버는 `터널 종단 + 세션 관리`
- client는 `자기 역할에 맞는 route 제어`

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

## 10. client-config-dir 사용 예시

특정 client에만 별도 정책을 줄 때는 `ccd`를 쓴다.

예시 파일:

`/etc/openvpn/server/ccd/ovpn-gw-pri-01`

```conf
# 예시: gateway client에 고정 tunnel IP를 주고 싶을 때
ifconfig-push <CCD_CLIENT_IP> <CCD_CLIENT_NETMASK>
```

메모:

- 실제로 `ifconfig-push`를 쓰려면 OpenVPN topology와 주소 계획이 정리돼 있어야 한다
- PoC에서는 동적 할당으로 시작하고, 운영형으로 갈 때 고정값을 검토해도 늦지 않다

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

검증:

```bash
sudo iptables -S
sudo iptables -t nat -S
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

## 14. DNS 관점에서 서버가 해야 할 일

OpenVPN 서버는 기본적으로 DNS 서버가 아니다. 하지만 client가 외부 DNS에 닿을 수 있게 해야 한다.

즉 서버 입장에서는 아래가 맞아야 한다.

- `tun0 -> eth0` forwarding 가능
- 외부 DNS 서버로 outbound 가능
- SNAT 정상 동작

지금 과업에서는 DNS를 서버에서 직접 해결하기보다, client 또는 CoreDNS upstream 설계에서 푸는 쪽이 단순하다.

## 15. 보안/운영 하드닝

- `CA private key`는 서버에 두지 않는다
- 서버 cert/key와 `tls-crypt.key` 파일 권한을 `0600`으로 유지한다
- `crl.pem` 갱신 절차를 운영 문서에 포함한다
- 보안그룹은 OpenVPN 포트와 필요한 운영 접근만 허용한다
- 로그 보존 기간과 용량을 정한다
- `duplicate-cn`은 허용하지 않는다

## 16. 장애 포인트

- OpenVPN 서버 프로세스 다운
- `tun0` 미생성
- NAT 규칙 유실
- `crl.pem` 손상 또는 권한 오류
- 서버의 인터넷 outbound 차단
- client가 서버 endpoint를 터널 쪽으로 잘못 보내는 라우팅 루프

## 17. 지금 과업 기준 최소 성공 조건

아래가 모두 맞아야 `Pod에서 curl google.com`이 성공한다.

- `Private VPC`와 `Public VPC` 간 peering 정상
- client가 `OpenVPN Server private IP`로 접속 가능
- 서버 `tun0` 생성
- 서버 `IP forwarding=1`
- 서버 `FORWARD/NAT` 정상
- client 쪽 bypass route 정상
- DNS 이름 해석 정상

## 18. 다음 단계

이 문서는 서버 설계/구축 기준 문서다. 실제 적용용 파일이 더 필요하면 다음을 별도로 만들면 된다.

- 실제 값이 들어간 `server.conf`
- `iptables-restore` 파일
- `sysctl.d` 파일
- `systemd override`
