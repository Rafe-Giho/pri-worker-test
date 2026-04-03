# Project AGENTS

이 파일은 전역 Codex 지침을 반복하지 않고, 이 저장소 전용 규칙만 적는다.

## 먼저 읽을 문서

1. [docs/context.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\docs\context.md)
2. [docs/architecture.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\docs\architecture.md)
3. [docs/decisions.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\docs\decisions.md)
4. [docs/handoff.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\docs\handoff.md)

세부 구현/운영은 아래 문서를 본다.

- [openvpn-nks-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-build-guide.md)
- [openvpn-nks-implementation-appendix.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-implementation-appendix.md)
- [openvpn-nks-operations-appendix.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-operations-appendix.md)
- [openvpn-server-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-server-build-guide.md)

## 이 저장소 전용 규칙

- 기존 대형 가이드는 함부로 요약하거나 삭제하지 않는다.
- 실제 적용용 파일과 설명 문서는 분리한다.
- 아키텍처나 운영 결정이 바뀌면 `docs/decisions.md`와 `docs/handoff.md`를 같이 갱신한다.

## 핵심 용어

- `NodeGroup-A`: worker node 자체가 OpenVPN client
- `NodeGroup-B`: worker egress next hop이 `VPN Gateway VM`
- `NodeGroup-C`: Pod sidecar가 OpenVPN client
- `CA Server`: `Private VPC`의 별도 VM이며 `NKS Cluster` 안이 아니다
- `OpenVPN Server`: `Public VPC`의 VPN 종단 및 egress NAT 장비
