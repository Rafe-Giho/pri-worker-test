# Context

## 목적

- `NHN testbed`의 `NKS Private Zone`에서 동작하는 폐쇄망 Pod가 `OpenVPN`을 경유해 외부 인터넷/API와 통신할 수 있는지 검토하고 구축 가이드를 정리한다.
- 대표 검증 목표는 `Pod에서 curl google.com 응답 받기`다.

## 현재 전제

- VPC는 `Public VPC`와 `Private VPC` 두 개를 사용한다.
- 두 VPC는 `Peering` 연결을 전제로 한다.
- OpenVPN 서버는 `Public VPC`에 둔다.
- CA 서버와 NKS는 `Private VPC`에 둔다.
- node group은 3개를 상정한다.
  - `NodeGroup-A`: worker node 자체가 OpenVPN client
  - `NodeGroup-B`: worker의 egress next hop이 `VPN Gateway VM`
  - `NodeGroup-C`: Pod sidecar가 OpenVPN client

## 핵심 문서

- 개요/구성안: [openvpn-nks-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-build-guide.md)
- 구현 부록: [openvpn-nks-implementation-appendix.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-implementation-appendix.md)
- 운영 부록: [openvpn-nks-operations-appendix.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-operations-appendix.md)
- 서버 상세: [openvpn-server-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-server-build-guide.md)

## 현재 상태

- 대형 가이드는 이미 분리되어 있다.
- 구현 부록에는 인증서 번들 규칙, bootstrap endpoint, Issuer API 설계, DNS 검증 포인트가 포함돼 있다.
- OpenVPN 서버는 별도 상세 문서로 분리되어 있다.
- 실제 적용용 `server.conf`는 아직 비어 있다.

## 주의할 점

- `curl google.com` 목표는 `VPN 연결`만으로는 안 되고 `DNS`, `routing`, `NAT`, `MTU`까지 맞아야 한다.
- `NodeGroup-B` 방식은 별도 subnet 또는 별도 route domain이 있어야 깔끔하다.
- `자동 발급`은 설계와 실제 구현을 구분해서 다뤄야 한다.
