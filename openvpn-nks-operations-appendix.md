# NKS OpenVPN 운영 부록

- 이 문서는 [openvpn-nks-build-guide.md](./openvpn-nks-build-guide.md)의 운영 부록이다.
- 기존 가이드의 `## 10. 인증서 갱신 / 폐기 / 교체`부터 `## 12. 트러블슈팅 체크리스트`까지를 원문 그대로 분리했다.
- 운영 절차와 명령어는 축약하지 않았다.

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
8. 서버에서 OpenVPN restart

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
- bootstrap endpoint 또는 secure distribution endpoint
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
  issued/
  revoked/
inventory/
  gateways.yml
  nodes.yml
manifests/
  sidecar/
```

### 11.3 신규 node / 신규 pod 대응 방향

신규 `worker node`:

- 구현 가능하며, 실무적으로도 자동화 가치가 높다
- 권장 흐름:
  1. node 생성
  2. user script 실행
  3. bootstrap endpoint에서 node별 bundle fetch
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

- `node`: 자동 발급 또는 사전 발급 풀 기반 자동화
- `pod`: 기본은 workload 단위, 고보안 요구 시에만 pod 단위 자동 발급

### 11.4 구현 흐름 예시

신규 `worker node` 자동화:

```text
1. node 생성
2. user script 시작
3. bootstrap endpoint에서 <NODE_ID>.tar.gz 요청
4. bundle download / 배치
5. openvpn-client@worker-egress 기동
6. 접속 확인 후 운영 편입
```

신규 `gateway VM` 자동화:

```text
1. gateway VM 생성
2. ovpn-gw-<id> cert/bundle 발급
3. bootstrap endpoint 또는 ansible로 bundle 배포
4. OpenVPN client 기동
5. 라우팅 / VIP 연결
```

신규 `sidecar workload` 자동화:

```text
1. workload 이름 기준 cert 발급
2. Kubernetes Secret 갱신
3. deployment rollout restart
4. sidecar 재기동 후 접속 확인
```

## 12. 트러블슈팅 체크리스트

### 12.1 연결 자체가 안 될 때

- `UDP/<OPENVPN_SERVER_PORT>` 보안 그룹 확인
- peering route 확인
- server/client `ca/cert/key/tls-crypt` 일치 여부 확인
- `remote-cert-tls server` 실패 여부 확인
- `crl.pem` 때문에 차단된 것인지 확인

### 12.2 연결은 되는데 인터넷이 안 될 때

- 서버의 `net.ipv4.ip_forward=1`
- 서버의 `POSTROUTING MASQUERADE`
- gateway VM 사용 시 gateway의 forwarding/NAT
- client route에 `OpenVPN 서버 endpoint via net_gateway` 예외가 있는지 확인

### 12.3 NKS 내부 통신이 깨질 때

- `NKS Pod CIDR`, `NKS Service CIDR`, `Private VPC CIDR`, `Public VPC CIDR` bypass route 확인
- CoreDNS ClusterIP가 VPN으로 빠지지 않는지 확인
- node/client 방식이면 kubelet/API server IP route 확인

### 12.4 MTU 문제

증상:

- 일부 API만 timeout
- 큰 payload에서만 실패

대응:

- `mssfix 1360`부터 테스트
- 필요시 `tun-mtu` 조정
- `tracepath`, `tcpdump -ni tun0`로 확인

