// v3-john SLO 기준선 측정. 정상 상태 사용자 흐름을 일정 부하로 보낸다.
// 실행: k6 run -e TOKENS=$OUT/tokens.json -e PROBLEMS=$OUT/problems.json [-e VUS=10 -e DURATION=10m] baseline.js
// 핵심: 내 정보, 데일리 문제, 문제 상세, 코드 제출(10%). 주요: 랭킹, 배틀 현황, 알림.
// AI(힌트, 풀이 평가)는 가짜 Gemini 서버가 없어 실제 비용이 나가므로 제외한다.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const tokens = JSON.parse(open(__ENV.TOKENS));
const BASE = __ENV.BASE || 'https://john.cosmoscode.site/api';
const SAVED = JSON.parse(open(__ENV.PROBLEMS)); // prepare.sh가 만든 저장 문제 ID
const VUS = parseInt(__ENV.VUS || '10');
const DURATION = __ENV.DURATION || '10m';

const readLatency = new Trend('read_latency', true);   // 로그인 확인, 데일리, 문제 상세
const submitLatency = new Trend('submit_latency', true); // 제출부터 채점 결과까지
const judgeIncomplete = new Counter('judge_incomplete'); // 채점 결과를 받지 못한 제출

export const options = {
  scenarios: {
    steady: { executor: 'constant-vus', vus: VUS, duration: DURATION },
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

function get(path, journey, trend) {
  const res = http.get(`${BASE}${path}`, { headers: hdr(), tags: { journey, name: path.replace(/\/\d+/g, '/{id}') } });
  check(res, { [`${journey} ${res.request.method} 2xx`]: (r) => r.status >= 200 && r.status < 300 });
  if (trend) trend.add(res.timings.duration);
  return res;
}

let token;
function hdr() { return { Cookie: `accessToken=${token}`, 'Content-Type': 'application/json' }; }

export default function () {
  token = tokens[(__VU - 1) % tokens.length];
  const pid = SAVED[Math.floor(Math.random() * SAVED.length)];

  get('/auth/me', 'core', readLatency);
  get('/daily-problems', 'core', readLatency);
  get(`/problems/${pid}`, 'core', readLatency);
  sleep(1);

  if (Math.random() < 0.1) {
    const res = http.post(`${BASE}/problems/${pid}/code-submissions`,
      JSON.stringify({ language: 'PYTHON', source_code: 'import sys\nprint(sys.stdin.read())' }),
      { headers: hdr(), timeout: '60s', tags: { journey: 'core', name: '/problems/{id}/code-submissions' } });
    submitLatency.add(res.timings.duration);
    const done = res.status === 200 && res.json('data.judging_status') === 'COMPLETED';
    if (!done) judgeIncomplete.add(1);
    check(res, { 'core submit judged': () => done });
    sleep(1);
  }

  get('/rankings', 'major');
  get('/daily-battles/current', 'major');
  get('/notifications', 'major');
  sleep(1);
}
