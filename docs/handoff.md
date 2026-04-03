# Handoff

## 현재 작업 상태

- 대형 가이드는 이미 정리돼 있다.
- OpenVPN 서버 상세 문서는 별도 파일로 분리됐다.
- 컨텍스트 복원용 `docs/` 구조를 별도 브랜치에 추가했다.

현재 브랜치:

- `docs-context-structure`

## 바로 이어서 할 수 있는 작업

1. 실제 값이 들어간 `server.conf` 초안 만들기
2. 실제 적용용 `worker-egress.conf`, `egress-gw.conf`, `sidecar client.conf` 파일 만들기
3. `Issuer API`를 실제 코드로 PoC 구현하기
4. NKS 환경값을 넣은 변수표 만들기
5. 팀두레이/보고용 축약본 만들기

## 아직 없는 것

- 실제 적용용 `server.conf`
- 실제 동작하는 `Issuer API` 서버 코드
- 실환경 테스트 결과
- 실제 subnet/route/security group 값

## 재개 시 우선 읽을 문서

1. [docs/context.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\docs\context.md)
2. [docs/architecture.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\docs\architecture.md)
3. [docs/decisions.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\docs\decisions.md)
4. [openvpn-nks-build-guide.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-build-guide.md)
5. [openvpn-nks-implementation-appendix.md](C:\Users\user\Desktop\신기호\업무용\30.PoC\openvpn\pri-worker-test\openvpn-nks-implementation-appendix.md)

## 유의사항

- `NodeGroup-B`는 별도 subnet/route domain 전제가 강하다.
- `curl google.com` 실패 시 OpenVPN만 보지 말고 `DNS -> route -> NAT` 순으로 본다.
- cloud task를 다른 기기에서 이어갈 때는 이 문서와 `docs/`를 먼저 읽게 하는 것이 안전하다.
