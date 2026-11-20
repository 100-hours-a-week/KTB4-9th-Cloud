// v3-john SLO 기준선과 장애 주입 실험의 사용자 흐름. 정상 상태 사용자 흐름을 일정 부하로 보낸다.
// 로컬:    k6 run -e TOKENS=$OUT/tokens.json -e PROBLEMS=$OUT/problems.json [-e VUS=10 -e DURATION=10m] baseline.js
// 클러스터: loadtest/k8s/run-k6.sh <testid> <duration> [vus] (BASE는 Envoy 내부 주소로 넘어온다)
// 핵심: 내 정보, 데일리 문제, 문제 상세, 코드 제출(SUBMIT_RATIO, 기본 10%). 주요: 랭킹, 배틀 현황, 알림.
// AI는 가짜 Gemini 서버가 있을 때만 AI=1로 켠다. 요청 시점에 LLM을 부르는 경로는 자연어 풀이 평가뿐이다
// (풀이 제출 202 → 평가 작업 조회로 SUCCEEDED/FAILED 확인). 힌트는 저장된 값이라 LLM을 부르지 않는다.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const tokens = JSON.parse(open(__ENV.TOKENS));
const BASE = __ENV.BASE || 'https://john.cosmoscode.site/api';
const SAVED = JSON.parse(open(__ENV.PROBLEMS)); // prepare.sh가 만든 저장 문제 ID
const VUS = parseInt(__ENV.VUS || '10');
const DURATION = __ENV.DURATION || '10m';
const SUBMIT_RATIO = parseFloat(__ENV.SUBMIT_RATIO || '0.1');
const THINK = parseFloat(__ENV.THINK || '1');
const AI = __ENV.AI === '1';
const AI_RATIO = parseFloat(__ENV.AI_RATIO || '0.05');
const AI_POLL_TIMEOUT = parseFloat(__ENV.AI_POLL_TIMEOUT || '60'); // 초

const readLatency = new Trend('read_latency', true);     // 로그인 확인, 데일리, 문제 상세
const submitLatency = new Trend('submit_latency', true); // 제출부터 채점 결과까지(동기 응답)
// 제출 결과는 셋 중 하나로 센다. 업무 거절(4xx)은 유실이 아니다.
const judgeCompleted = new Counter('judge_completed');   // 200이고 COMPLETED
const judgeLost = new Counter('judge_lost');             // 5xx, 시간 초과, 2xx인데 COMPLETED가 아님
const submitRejected = new Counter('submit_rejected');   // 4xx, status 태그로 코드 구분
const aiEvalLatency = new Trend('ai_eval_latency', true); // 풀이 제출부터 평가 완료(SUCCEEDED/FAILED)까지
const aiEvalSucceeded = new Counter('ai_eval_succeeded');
const aiEvalFailed = new Counter('ai_eval_failed');       // FAILED, 조회 시간 초과, 제출 5xx
const aiRejected = new Counter('ai_rejected');            // 제출 4xx(제출 횟수 제한 등)

export const options = {
  scenarios: {
    steady: { executor: 'constant-vus', vus: VUS, duration: DURATION },
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

let token;
function hdr() { return { Cookie: `accessToken=${token}`, 'Content-Type': 'application/json' }; }

function get(path, journey, trend) {
  const res = http.get(`${BASE}${path}`, { headers: hdr(), tags: { journey, name: path.replace(/\/\d+/g, '/{id}') } });
  check(res, { [`${journey} GET 2xx`]: (r) => r.status >= 200 && r.status < 300 });
  if (trend) trend.add(res.timings.duration);
  return res;
}

// 4xx 본문은 VU 1~5에서 한 건씩만 남긴다(전체 최대 5건). 2026-11-19 2회차 제출 4xx 18건의 원인 확인용.
let warned4xx = false;
function submit(pid) {
  const res = http.post(`${BASE}/problems/${pid}/code-submissions`,
    JSON.stringify({ language: 'PYTHON', source_code: 'import sys\nprint(sys.stdin.read())' }),
    { headers: hdr(), timeout: '60s', tags: { journey: 'core', name: '/problems/{id}/code-submissions' } });
  submitLatency.add(res.timings.duration);
  let status = 'lost';
  if (res.status >= 400 && res.status < 500) {
    status = 'rejected';
    submitRejected.add(1, { status: String(res.status) });
    if (!warned4xx && __VU <= 5) {
      warned4xx = true;
      console.warn(`submit 4xx status=${res.status} problem=${pid} body=${String(res.body).slice(0, 300)}`);
    }
  } else if (res.status === 200 && res.json('data.judging_status') === 'COMPLETED') {
    status = 'completed';
    judgeCompleted.add(1);
  } else {
    judgeLost.add(1, { status: String(res.status) });
  }
  check(res, { 'core submit judged': () => status === 'completed' });
}

function evaluateSolution(pid) {
  const start = Date.now();
  const res = http.post(`${BASE}/problems/${pid}/solution-submissions`,
    JSON.stringify({ selectedCategory: 'ARRAY', natural_solution: '배열을 한 번 순회하며 누적 합을 구하고 조건을 만족하는 구간을 센다.' }),
    { headers: hdr(), tags: { journey: 'ai', name: '/problems/{id}/solution-submissions' } });
  if (res.status >= 400 && res.status < 500) { aiRejected.add(1, { status: String(res.status) }); return; }
  if (res.status !== 202) { aiEvalFailed.add(1, { reason: `submit_${res.status}` }); return; }
  const taskId = res.json('data.evaluationTaskId');
  while ((Date.now() - start) / 1000 < AI_POLL_TIMEOUT) {
    sleep(Math.min(2, AI_POLL_TIMEOUT / 4));
    const r = http.get(`${BASE}/solution-evaluations/${taskId}`,
      { headers: hdr(), tags: { journey: 'ai', name: '/solution-evaluations/{id}' } });
    const st = r.status === 200 ? r.json('data.status') : null;
    if (st === 'SUCCEEDED' || st === 'FAILED') {
      aiEvalLatency.add(Date.now() - start);
      if (st === 'SUCCEEDED') aiEvalSucceeded.add(1); else aiEvalFailed.add(1, { reason: 'failed' });
      return;
    }
  }
  aiEvalFailed.add(1, { reason: 'timeout' });
}

export default function () {
  token = tokens[(__VU - 1) % tokens.length];
  const pid = SAVED[Math.floor(Math.random() * SAVED.length)];

  get('/auth/me', 'core', readLatency);
  get('/daily-problems', 'core', readLatency);
  get(`/problems/${pid}`, 'core', readLatency);
  sleep(THINK);

  if (Math.random() < SUBMIT_RATIO) {
    submit(pid);
    sleep(THINK);
  }

  if (AI && Math.random() < AI_RATIO) {
    evaluateSolution(pid);
  }

  get('/rankings', 'major');
  get('/daily-battles/current', 'major');
  get('/notifications', 'major');
  sleep(THINK);
}

// 클러스터 실행에서는 파드가 끝나면 파일을 꺼낼 수 없으므로 요약을 표준 출력에 표식과 함께 남긴다.
// 형식은 --summary-export와 같게 맞춘다(지표 이름 → 값 객체, rate 지표는 value 키). analyze.py가 그대로 읽는다.
export function handleSummary(data) {
  const metrics = {};
  for (const [name, m] of Object.entries(data.metrics)) {
    const v = Object.assign({}, m.values);
    if (m.type === 'rate') v.value = m.values.rate;
    metrics[name] = v;
  }
  const json = JSON.stringify({ metrics, root_group: data.root_group, state: data.state });
  const out = { stdout: `\n@@K6_SUMMARY@@${json}\n` };
  if (__ENV.SUMMARY_OUT) out[__ENV.SUMMARY_OUT] = json;
  return out;
}
