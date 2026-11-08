<template>
  <section class="panel">
    <section v-if="!sessionLoaded" class="loading-card">
      <p>{{ t('compileForm.loading') }}</p>
    </section>

    <template v-else>
      <section v-if="isAuthenticated && missingScopes.length > 0" class="status warning">
        {{ t('compileForm.missingScopes', { scopes: missingScopes.join(', ') }) }}
      </section>

      <form class="form" @submit.prevent="handleSubmit">
        <div class="field">
          <span>{{ t('compileForm.fields.ini.label') }}</span>
          <CodeEditor v-model="ini" language="ini" />
          <p class="field-hint">{{ t('compileForm.fields.ini.hint') }}</p>
        </div>

        <div class="field">
          <span>{{ t('compileForm.fields.sketch.label') }}</span>
          <CodeEditor v-model="sketch" language="cpp" />
          <p class="field-hint">{{ t('compileForm.fields.sketch.hint') }}</p>
        </div>

        <label class="field">
          <span>{{ t('compileForm.fields.artifactPassword.label') }}</span>
          <div class="password-input">
            <input
              v-model="artifactPassword"
              type="text"
              inputmode="text"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="none"
              spellcheck="false"
              maxlength="64"
              :placeholder="t('compileForm.fields.artifactPassword.placeholder')"
              :disabled="pending"
            />
            <button
              type="button"
              class="ghost mini"
              :disabled="pending"
              @click="regenerateArtifactPassword"
            >
              {{ t('compileForm.fields.artifactPassword.regenerate') }}
            </button>
          </div>
          <p class="field-hint">
            {{ t('compileForm.fields.artifactPassword.hint') }}
          </p>
        </label>

        <details class="advanced">
          <summary>{{ t('compileForm.advanced.summary') }}</summary>
          <label class="field">
            <span>{{ t('compileForm.fields.pioVersion.label') }}</span>
            <input
              v-model="pioVersion"
              type="text"
              inputmode="text"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="none"
              spellcheck="false"
              maxlength="32"
              :placeholder="t('compileForm.fields.pioVersion.placeholder')"
              :disabled="pending"
            />
            <p class="field-hint">{{ t('compileForm.fields.pioVersion.hint') }}</p>
          </label>
        </details>

        <div class="actions">
          <div class="primary-actions">
            <button :class="{ loading: pending }" :disabled="pending || !canSubmit" type="submit">
              {{ pending ? t('compileForm.actions.submitting') : t('compileForm.actions.submit') }}
            </button>
            <button :disabled="!canReset" class="ghost" type="button" @click="reset">
              {{ t('compileForm.actions.reset') }}
            </button>
          </div>
          <div class="auth-controls">
            <div v-if="isAuthenticated" class="auth-user">
              <img
                v-if="user?.avatarUrl"
                :src="user.avatarUrl"
                :alt="t('compileForm.auth.avatarAlt')"
              />
              <div v-else class="avatar-fallback">
                {{ user?.login?.[0]?.toUpperCase() ?? 'G' }}
              </div>
              <button class="ghost mini" type="button" @click="logout">
                {{ t('compileForm.auth.logout') }}
              </button>
            </div>
            <button
              v-else
              type="button"
              class="ghost mini"
              :class="{ loading: authLoading }"
              :disabled="authLoading"
              @click="login"
            >
              {{ t('compileForm.auth.login') }}
            </button>
          </div>
        </div>
        <p v-if="shouldEncouragePersonal && !isAuthenticated" class="personal-hint">
          {{ t('compileForm.auth.encouragePersonal') }}
        </p>
        <p v-if="submitHint" class="status warning">{{ submitHint }}</p>
        <p v-if="error" class="status error">{{ error }}</p>
      </form>

      <section v-if="requestId" class="status-card">
        <h2>{{ t('compileForm.status.sectionTitle') }}</h2>
        <p><strong>{{ t('compileForm.status.requestId') }}</strong> {{ requestId }}</p>
        <p v-if="runId"><strong>{{ t('compileForm.status.runId') }}</strong> {{ runId }}</p>
        <p>
          <strong>{{ t('compileForm.status.currentStatus') }}</strong>
          <span :class="['badge', statusClass]">
            <span v-if="isStatusLoading" class="badge-spinner" aria-hidden="true"></span>
            {{ displayStatus }}
          </span>
        </p>
        <p v-if="runUrl">
          <strong>{{ t('compileForm.status.runLinkLabel') }}</strong>
          <button class="link-button" type="button" @click.prevent="openRunUrl">
            {{ t('compileForm.status.openRun') }}
          </button>
        </p>
        <p v-if="submittedPioVersion">
          <strong>{{ t('compileForm.status.pioVersion') }}</strong> {{ submittedPioVersion }}
        </p>
        <p>
          <strong>{{ t('compileForm.status.artifactPassword') }}</strong>
          <span class="password-display">{{ artifactPassword }}</span>
        </p>
        <p v-if="artifact && artifactUrl">
          <strong>{{ t('compileForm.status.artifact') }}</strong>
          <button
            :disabled="downloadingArtifact"
            :class="['ghost', { loading: downloadingArtifact }]"
            type="button"
            @click="downloadArtifact"
          >
            {{
              downloadingArtifact
                ? t('compileForm.status.downloading')
                : t('compileForm.status.downloadArtifact', { name: artifact.name })
            }}
          </button>
        </p>

        <section v-if="jobLogs" class="error-logs">
          <h3>{{ t('compileForm.status.errorLogs') }}</h3>
          <pre class="log-content">{{ jobLogs }}</pre>
        </section>
        <section v-else-if="loadingLogs" class="error-logs">
          <p class="loading-text">{{ t('compileForm.status.loadingLogs') }}</p>
        </section>
      </section>
    </template>
  </section>
</template>

<script setup lang="ts">
import axios from 'axios';
import { Base64 } from 'js-base64';
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import CodeEditor from './CodeEditor.vue';

type TokenSource = 'service' | 'session';

type SessionPayload = {
  authenticated: boolean;
  serviceTokenAvailable?: boolean;
  defaultTokenSource?: TokenSource | null;
  user?: {
    login: string;
    name: string | null;
    avatarUrl: string | null;
    htmlUrl: string | null;
  } | null;
  tokenScopes?: string[];
  missingScopes?: string[];
  repo?: {
    owner: string;
    name: string;
    workflowId: string;
    ref: string;
  } | null;
};

type WorkflowStatus = {
  status: string;
  conclusion: string;
  message: string;
  failedJobId?: number | null;
};

type ArtifactMeta = {
  id: number;
  name: string;
};

type PersistedJobState = {
  requestId: string;
  runId: number | null;
  runUrl: string | null;
  status: WorkflowStatus;
  artifact: ArtifactMeta | null;
  artifactUrl: string | null;
  artifactPassword?: string | null;
  tokenSource: TokenSource | null;
  pioVersion?: string | null;
};

type ApiErrorPayload = {
  message?: string;
  serviceTokenDegraded?: boolean;
};

const { t, te } = useI18n();

const STORAGE_PREFIX = 'arduino-online-compiler';
const STORAGE_INI_KEY = `${STORAGE_PREFIX}:platformio-ini`;
const STORAGE_SKETCH_KEY = `${STORAGE_PREFIX}:main-cpp`;
const STORAGE_JOB_KEY = `${STORAGE_PREFIX}:job-state`;
const STORAGE_PASSWORD_KEY = `${STORAGE_PREFIX}:artifact-password`;
const STORAGE_PIO_VERSION_KEY = `${STORAGE_PREFIX}:pio-version`;

const MAX_INI_BYTES = 24 * 1024;
const MAX_SKETCH_BYTES = 64 * 1024;

const DEFAULT_INI = `[env:esp32dev]
platform = espressif32
board = esp32dev
framework = arduino
monitor_speed = 115200

; 依赖库（可选），例如：
; lib_deps =
;   bblanchon/ArduinoJson@^6.21.5
`;

const DEFAULT_SKETCH = `#include <Arduino.h>

// 板载 LED 引脚（ESP32 DevKit 通常为 GPIO2）
#define LED_PIN 2

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  Serial.println("Hello from Arduino online compiler!");
}

void loop() {
  digitalWrite(LED_PIN, HIGH);
  delay(1000);
  digitalWrite(LED_PIN, LOW);
  delay(1000);
}
`;

const client = axios.create({
  withCredentials: true
});

const session = ref<SessionPayload | null>(null);
const sessionLoaded = ref(false);

const ini = ref(DEFAULT_INI);
const sketch = ref(DEFAULT_SKETCH);
const pioVersion = ref('');
const runId = ref<number | null>(null);
const requestId = ref<string | null>(null);
const runUrl = ref<string | null>(null);
const artifactUrl = ref<string | null>(null);
const artifact = ref<ArtifactMeta | null>(null);
const artifactPassword = ref('');
const submittedPioVersion = ref<string | null>(null);
const pending = ref(false);
const downloadingArtifact = ref(false);
const error = ref<string | null>(null);
const pollTimer = ref<number | null>(null);
const preferPersonalToken = ref(false);
const lastTokenSource = ref<TokenSource | null>(null);
const serviceTokenDegraded = ref(false);
const authLoading = ref(false);
const jobLogs = ref<string | null>(null);
const loadingLogs = ref(false);

const status = reactive<WorkflowStatus>({
  status: '',
  conclusion: '',
  message: '',
  failedJobId: null
});

const isAuthenticated = computed(() => Boolean(session.value?.authenticated));
const user = computed(() => session.value?.user ?? null);
const missingScopes = computed(() => session.value?.missingScopes ?? []);
const serviceTokenAvailable = computed(() => Boolean(session.value?.serviceTokenAvailable));
const canUsePersonalToken = computed(
  () => isAuthenticated.value && missingScopes.value.length === 0
);
const shouldEncouragePersonal = computed(
  () => !serviceTokenAvailable.value || serviceTokenDegraded.value
);
const canSubmit = computed(() => {
  if (preferPersonalToken.value) {
    return canUsePersonalToken.value;
  }
  if (serviceTokenAvailable.value && !serviceTokenDegraded.value) {
    return true;
  }
  return canUsePersonalToken.value;
});
const submitHint = computed(() => {
  if (canSubmit.value || serviceTokenDegraded.value) {
    return null;
  }
  if (!isAuthenticated.value) {
    return t('compileForm.submitHints.loginRequired');
  }
  if (missingScopes.value.length > 0) {
    return t('compileForm.submitHints.missingScopes');
  }
  return null;
});

const canReset = computed(() => {
  if (pending.value) {
    return false;
  }
  if (runId.value || requestId.value) {
    return true;
  }
  return ini.value !== DEFAULT_INI || sketch.value !== DEFAULT_SKETCH;
});

const displayStatus = computed(() => {
  if (!status.status) {
    return t('compileForm.statusDisplay.notStarted');
  }
  if (status.status === 'completed') {
    if (status.conclusion) {
      const conclusionKey = `compileForm.statusDisplay.conclusion.${status.conclusion}`;
      if (te(conclusionKey)) {
        return t(conclusionKey);
      }
      return status.conclusion;
    }
    return t('compileForm.statusDisplay.completed');
  }
  const statusKey = `compileForm.statusDisplay.status.${status.status}`;
  if (te(statusKey)) {
    return t(statusKey);
  }
  return status.status;
});

const statusClass = computed(() => {
  if (!status.status) return 'default';
  if (status.status === 'completed') {
    return status.conclusion === 'success' ? 'success' : 'error';
  }
  if (status.status === 'queued') {
    return 'queued';
  }
  if (status.status === 'in_progress') {
    return 'in-progress';
  }
  return 'progress';
});

const isStatusLoading = computed(
  () => status.status === 'queued' || status.status === 'in_progress'
);

function applyServiceTokenDegraded(payload: ApiErrorPayload | undefined) {
  if (payload?.serviceTokenDegraded) {
    serviceTokenDegraded.value = true;
    if (isAuthenticated.value && missingScopes.value.length === 0) {
      preferPersonalToken.value = true;
    }
  }
}

function generateRandomPassword(length = 16): string {
  const characters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const bucketLength = characters.length;
  if (length <= 0) {
    return '';
  }
  const cryptoObj = typeof globalThis !== 'undefined' ? globalThis.crypto ?? null : null;
  if (cryptoObj && typeof cryptoObj.getRandomValues === 'function') {
    const randomValues = new Uint32Array(length);
    cryptoObj.getRandomValues(randomValues);
    return Array.from(randomValues, (value) => characters[value % bucketLength]).join('');
  }
  let result = '';
  for (let index = 0; index < length; index += 1) {
    const randomIndex = Math.floor(Math.random() * bucketLength);
    result += characters[randomIndex];
  }
  return result;
}

function readStorage(key: string): string | null {
  if (typeof window === 'undefined') {
    return null;
  }
  try {
    return window.localStorage.getItem(key);
  } catch (err) {
    console.warn('Failed to read from localStorage', err);
    return null;
  }
}

function writeStorage(key: string, value: string | null) {
  if (typeof window === 'undefined') {
    return;
  }
  try {
    if (value) {
      window.localStorage.setItem(key, value);
    } else {
      window.localStorage.removeItem(key);
    }
  } catch (err) {
    console.warn('Failed to write to localStorage', err);
  }
}

function persistPassword(value: string) {
  writeStorage(STORAGE_PASSWORD_KEY, value);
}

function restorePassword() {
  const saved = readStorage(STORAGE_PASSWORD_KEY);
  if (saved && /^[A-Za-z0-9]{8,64}$/.test(saved)) {
    artifactPassword.value = saved;
    return;
  }
  artifactPassword.value = generateRandomPassword();
  persistPassword(artifactPassword.value);
}

function restoreDrafts() {
  const savedIni = readStorage(STORAGE_INI_KEY);
  const savedSketch = readStorage(STORAGE_SKETCH_KEY);
  if (savedIni) {
    ini.value = savedIni;
  }
  if (savedSketch) {
    sketch.value = savedSketch;
  }
}

function persistDrafts() {
  writeStorage(STORAGE_INI_KEY, ini.value || null);
  writeStorage(STORAGE_SKETCH_KEY, sketch.value || null);
}

let draftTimer: number | null = null;
function scheduleDraftsPersist() {
  if (typeof window === 'undefined') {
    return;
  }
  if (draftTimer !== null) {
    window.clearTimeout(draftTimer);
  }
  draftTimer = window.setTimeout(() => {
    draftTimer = null;
    persistDrafts();
  }, 400);
}

function restorePioVersion() {
  const saved = readStorage(STORAGE_PIO_VERSION_KEY);
  if (saved && /^\d+\.\d+\.\d+$/.test(saved)) {
    pioVersion.value = saved;
  }
}

function regenerateArtifactPassword() {
  artifactPassword.value = generateRandomPassword();
}

function openRunUrl() {
  if (!runUrl.value) return;
  window.open(runUrl.value, '_blank', 'noopener,noreferrer');
}

onMounted(() => {
  restoreDrafts();
  restorePassword();
  restorePioVersion();
  loadSession();
});

watch([ini, sketch], () => {
  scheduleDraftsPersist();
});

watch([artifactPassword, pioVersion], () => {
  persistPassword(artifactPassword.value);
  writeStorage(STORAGE_PIO_VERSION_KEY, pioVersion.value.trim() || null);
  if (requestId.value) {
    persistJobState();
  }
});

watch([isAuthenticated, shouldEncouragePersonal], ([authed, encourage]) => {
  if (encourage && authed && missingScopes.value.length === 0) {
    preferPersonalToken.value = true;
  } else if (!authed) {
    preferPersonalToken.value = false;
  }
});

watch(missingScopes, (scopes) => {
  if (scopes.length > 0) {
    preferPersonalToken.value = false;
  }
});

async function loadSession() {
  sessionLoaded.value = false;
  try {
    const { data } = await client.get<SessionPayload>('/api/session');
    session.value = data;
    serviceTokenDegraded.value = !data.serviceTokenAvailable;
    if (
      !data.serviceTokenAvailable &&
      data.authenticated &&
      (data.missingScopes?.length ?? 0) === 0
    ) {
      preferPersonalToken.value = true;
    } else if (data.serviceTokenAvailable) {
      preferPersonalToken.value = false;
    }
  } catch (err) {
    console.error('Failed to load session', err);
    session.value = { authenticated: false };
    preferPersonalToken.value = false;
    serviceTokenDegraded.value = true;
  } finally {
    sessionLoaded.value = true;
    if (isAuthenticated.value || serviceTokenAvailable.value) {
      await restoreJobState();
    } else {
      clearJobState();
    }
    authLoading.value = false;
  }
}

function login() {
  if (authLoading.value) return;
  authLoading.value = true;
  window.location.href = '/auth/login';
}

function logout() {
  clearJobState();
  window.location.href = '/auth/logout';
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).length;
}

async function handleSubmit() {
  if (!ini.value.trim()) {
    error.value = t('compileForm.errors.iniRequired');
    return;
  }
  if (!sketch.value.trim()) {
    error.value = t('compileForm.errors.sketchRequired');
    return;
  }
  if (byteLength(ini.value) > MAX_INI_BYTES) {
    error.value = t('compileForm.errors.iniTooLarge');
    return;
  }
  if (byteLength(sketch.value) > MAX_SKETCH_BYTES) {
    error.value = t('compileForm.errors.sketchTooLarge');
    return;
  }

  const versionToUse = pioVersion.value.trim();
  if (versionToUse && !/^\d+\.\d+\.\d+$/.test(versionToUse)) {
    error.value = t('compileForm.errors.pioVersionInvalid');
    return;
  }

  const wantsPersonalToken =
    preferPersonalToken.value || !serviceTokenAvailable.value || serviceTokenDegraded.value;
  if (wantsPersonalToken) {
    if (!isAuthenticated.value) {
      error.value = t('compileForm.errors.loginRequired');
      return;
    }
    if (!canUsePersonalToken.value) {
      error.value = t('compileForm.errors.missingScopes');
      return;
    }
  } else if (!serviceTokenAvailable.value && !isAuthenticated.value) {
    error.value = t('compileForm.errors.loginRequired');
    return;
  }

  const normalizedPassword = artifactPassword.value.trim();
  if (!normalizedPassword) {
    error.value = t('compileForm.errors.passwordRequired');
    return;
  }
  if (normalizedPassword.length < 8 || normalizedPassword.length > 64) {
    error.value = t('compileForm.errors.passwordLength');
    return;
  }
  if (!/^[A-Za-z0-9]+$/.test(normalizedPassword)) {
    error.value = t('compileForm.errors.passwordCharset');
    return;
  }
  if (normalizedPassword !== artifactPassword.value) {
    artifactPassword.value = normalizedPassword;
  }

  clearPolling();
  requestId.value = null;
  runId.value = null;
  runUrl.value = null;
  artifactUrl.value = null;
  artifact.value = null;
  status.status = '';
  status.conclusion = '';
  status.message = '';
  status.failedJobId = null;
  jobLogs.value = null;
  error.value = null;

  pending.value = true;

  try {
    const payload: {
      encodedIni: string;
      encodedSketch: string;
      artifactPassword: string;
      useUserToken?: boolean;
      pioVersion?: string;
    } = {
      encodedIni: Base64.encode(ini.value),
      encodedSketch: Base64.encode(sketch.value),
      artifactPassword: normalizedPassword
    };

    if (versionToUse) {
      payload.pioVersion = versionToUse;
    }

    if (wantsPersonalToken && canUsePersonalToken.value) {
      payload.useUserToken = true;
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    if (wantsPersonalToken && canUsePersonalToken.value) {
      headers['X-GitHub-Token-Source'] = 'session';
    }

    const { data } = await client.post<{
      requestId: string;
      runId: number | null;
      htmlUrl?: string | null;
      message?: string | null;
      tokenSource?: TokenSource | null;
    }>('/api/compile', payload, { headers });

    requestId.value = data.requestId;
    runId.value = data.runId;
    runUrl.value = data.htmlUrl ?? null;
    submittedPioVersion.value = versionToUse || null;
    status.status = 'queued';
    status.conclusion = '';
    status.message = data.message ?? t('compileForm.status.workflowQueued');
    status.failedJobId = null;

    const resolvedSource =
      data.tokenSource ??
      (wantsPersonalToken && canUsePersonalToken.value
        ? 'session'
        : serviceTokenAvailable.value && !serviceTokenDegraded.value
          ? 'service'
          : canUsePersonalToken.value
            ? 'session'
            : null);
    lastTokenSource.value = resolvedSource;

    if (resolvedSource === 'service' && serviceTokenAvailable.value) {
      serviceTokenDegraded.value = false;
      if (!shouldEncouragePersonal.value) {
        preferPersonalToken.value = false;
      }
    } else if (resolvedSource === 'session') {
      serviceTokenDegraded.value = true;
      if (isAuthenticated.value && missingScopes.value.length === 0) {
        preferPersonalToken.value = true;
      }
    }

    persistJobState();
    startPolling();
  } catch (err) {
    console.error('Failed to trigger compilation', err);
    const payload = axios.isAxiosError(err)
      ? (err.response?.data as ApiErrorPayload | undefined)
      : undefined;
    const message = payload?.message ?? t('compileForm.errors.triggerFailed');
    applyServiceTokenDegraded(payload);
    error.value = payload?.serviceTokenDegraded ? null : message;
  } finally {
    pending.value = false;
  }
}

function startPolling() {
  clearPolling();
  pollTimer.value = window.setInterval(async () => {
    try {
      await refreshStatus();
    } catch (err) {
      console.error('Failed to refresh workflow status', err);
      const payload = axios.isAxiosError(err)
        ? (err.response?.data as ApiErrorPayload | undefined)
        : undefined;
      const message = payload?.message ?? t('compileForm.errors.statusFailed');
      applyServiceTokenDegraded(payload);
      error.value = payload?.serviceTokenDegraded ? null : message;
      clearPolling();
    }
  }, 10_000);
}

async function refreshStatus() {
  if (!requestId.value) {
    return;
  }

  const target = runId.value ? String(runId.value) : requestId.value;
  const tokenHeaders =
    (preferPersonalToken.value || serviceTokenDegraded.value) && canUsePersonalToken.value
      ? { 'X-GitHub-Token-Source': 'session' }
      : undefined;

  const { data } = await client.get<{
    runId: number;
    status: string;
    conclusion: string | null;
    htmlUrl: string | null;
    artifactUrl: string | null;
    artifact: ArtifactMeta | null;
    message: string | null;
    failedJobId: number | null;
  }>(`/api/status/${encodeURIComponent(target)}`, {
    headers: tokenHeaders
  });

  runId.value = data.runId ?? runId.value;
  runUrl.value = data.htmlUrl ?? runUrl.value;
  artifactUrl.value = data.artifactUrl ?? null;
  artifact.value = data.artifact ?? null;
  status.status = data.status ?? '';
  status.conclusion = data.conclusion ?? '';
  status.message = data.message ?? '';
  status.failedJobId = data.failedJobId ?? null;

  if (data.status === 'completed') {
    clearPolling();
    if (data.conclusion !== 'success' && data.failedJobId) {
      await fetchJobLogs(data.failedJobId);
    }
  }

  persistJobState();
}

async function downloadArtifact() {
  if (!artifactUrl.value) return;
  downloadingArtifact.value = true;

  try {
    const tokenHeaders =
      (preferPersonalToken.value || serviceTokenDegraded.value) && canUsePersonalToken.value
        ? { 'X-GitHub-Token-Source': 'session' }
        : undefined;
    const response = await client.get<ArrayBuffer>(artifactUrl.value, {
      responseType: 'arraybuffer',
      headers: tokenHeaders
    });
    const blob = new Blob([response.data], { type: 'application/zip' });
    const blobUrl = window.URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = blobUrl;
    link.download = `${artifact.value?.name ?? 'firmware'}.zip`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.URL.revokeObjectURL(blobUrl);
    persistJobState();
  } catch (err) {
    console.error('Failed to download artifact', err);
    const payload = axios.isAxiosError(err)
      ? (err.response?.data as ApiErrorPayload | undefined)
      : undefined;
    const message = payload?.message ?? t('compileForm.errors.downloadFailed');
    applyServiceTokenDegraded(payload);
    error.value = payload?.serviceTokenDegraded ? null : message;
  } finally {
    downloadingArtifact.value = false;
  }
}

async function fetchJobLogs(jobId: number) {
  if (loadingLogs.value) return;
  loadingLogs.value = true;
  jobLogs.value = null;

  try {
    const tokenHeaders =
      (preferPersonalToken.value || serviceTokenDegraded.value) && canUsePersonalToken.value
        ? { 'X-GitHub-Token-Source': 'session' }
        : undefined;
    const { data } = await client.get<{ errorLogs: string | null }>(`/api/jobs/${jobId}`, {
      headers: tokenHeaders
    });
    jobLogs.value = data.errorLogs;
  } catch (err) {
    console.error('Failed to fetch job logs', err);
    const payload = axios.isAxiosError(err)
      ? (err.response?.data as ApiErrorPayload | undefined)
      : undefined;
    applyServiceTokenDegraded(payload);
    jobLogs.value = null;
  } finally {
    loadingLogs.value = false;
  }
}

async function restoreJobState() {
  if (requestId.value) {
    return;
  }
  if (typeof window === 'undefined') {
    return;
  }
  if (!isAuthenticated.value && !serviceTokenAvailable.value) {
    clearPersistedJob();
    return;
  }
  try {
    const raw = window.localStorage.getItem(STORAGE_JOB_KEY);
    if (!raw) {
      return;
    }
    const saved = JSON.parse(raw) as Partial<PersistedJobState> | null;
    if (!saved || !saved.requestId) {
      return;
    }

    requestId.value = saved.requestId;
    runId.value = saved.runId ?? null;
    runUrl.value = saved.runUrl ?? null;
    status.status = saved.status?.status ?? '';
    status.conclusion = saved.status?.conclusion ?? '';
    status.message = saved.status?.message ?? '';
    status.failedJobId = saved.status?.failedJobId ?? null;
    artifact.value = saved.artifact ?? null;
    submittedPioVersion.value = saved.pioVersion ?? null;
    lastTokenSource.value = saved.tokenSource ?? null;

    if (saved.tokenSource === 'session') {
      serviceTokenDegraded.value = true;
      if (serviceTokenAvailable.value && canUsePersonalToken.value) {
        preferPersonalToken.value = true;
      }
    } else if (saved.tokenSource === 'service' && serviceTokenAvailable.value) {
      serviceTokenDegraded.value = false;
    }

    if (saved.artifactUrl) {
      artifactUrl.value = saved.artifactUrl;
    } else if (saved.runId != null && saved.artifact) {
      artifactUrl.value = `/api/artifacts/${saved.runId}/${saved.artifact.id}`;
    } else {
      artifactUrl.value = null;
    }
    if (saved.artifactPassword) {
      artifactPassword.value = saved.artifactPassword;
    }

    pending.value = false;
    downloadingArtifact.value = false;
    error.value = null;

    if (status.status && status.status !== 'completed') {
      startPolling();
    } else if (
      status.status === 'completed' &&
      status.conclusion !== 'success' &&
      saved.status?.failedJobId
    ) {
      await fetchJobLogs(saved.status.failedJobId);
    }

    persistJobState();
  } catch (err) {
    console.warn('Failed to restore job state', err);
    clearPersistedJob();
  }
}

function persistJobState() {
  if (typeof window === 'undefined') {
    return;
  }

  if (!requestId.value) {
    clearPersistedJob();
    return;
  }

  const payload: PersistedJobState = {
    requestId: requestId.value,
    runId: runId.value,
    runUrl: runUrl.value,
    status: {
      status: status.status,
      conclusion: status.conclusion,
      message: status.message,
      failedJobId: status.failedJobId ?? null
    },
    artifact: artifact.value ? { ...artifact.value } : null,
    artifactUrl: artifactUrl.value,
    artifactPassword: artifactPassword.value || null,
    tokenSource: lastTokenSource.value ?? null,
    pioVersion: submittedPioVersion.value
  };

  try {
    window.localStorage.setItem(STORAGE_JOB_KEY, JSON.stringify(payload));
  } catch (err) {
    console.warn('Failed to persist job state', err);
  }
}

function clearPersistedJob() {
  writeStorage(STORAGE_JOB_KEY, null);
}

function clearPolling() {
  if (pollTimer.value !== null) {
    window.clearInterval(pollTimer.value);
    pollTimer.value = null;
  }
}

function clearJobState() {
  clearPolling();
  requestId.value = null;
  runId.value = null;
  runUrl.value = null;
  artifactUrl.value = null;
  artifact.value = null;
  submittedPioVersion.value = null;
  status.status = '';
  status.conclusion = '';
  status.message = '';
  status.failedJobId = null;
  lastTokenSource.value = null;
  error.value = null;
  downloadingArtifact.value = false;
  pending.value = false;
  jobLogs.value = null;
  clearPersistedJob();
}

function reset() {
  clearJobState();
  ini.value = DEFAULT_INI;
  sketch.value = DEFAULT_SKETCH;
  persistDrafts();
}

onBeforeUnmount(() => {
  clearPolling();
  if (draftTimer !== null) {
    window.clearTimeout(draftTimer);
    draftTimer = null;
  }
});
</script>

<style scoped>
.panel {
  background: rgba(15, 23, 42, 0.8);
  backdrop-filter: blur(8px);
  border: 1px solid rgba(148, 163, 184, 0.3);
  border-radius: 16px;
  padding: 1.5rem;
  box-shadow: 0 10px 30px rgba(15, 15, 80, 0.2);
  display: grid;
  gap: 1.5rem;
}

.loading-card {
  text-align: center;
  padding: 2rem 1rem;
  background: rgba(30, 41, 59, 0.6);
  border-radius: 12px;
  border: 1px solid rgba(148, 163, 184, 0.2);
}

.form {
  display: grid;
  gap: 1.25rem;
}

.field {
  display: grid;
  gap: 0.5rem;
  font-size: 0.95rem;
  color: #e2e8f0;
}

.field-hint {
  margin: 0;
  font-size: 0.8rem;
  color: #94a3b8;
}

.password-input {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.password-input input {
  flex: 1;
}

.password-display {
  display: inline-flex;
  align-items: center;
  padding: 0.15rem 0.6rem;
  border-radius: 8px;
  background: rgba(15, 23, 42, 0.7);
  border: 1px solid rgba(148, 163, 184, 0.35);
  color: #e0f2fe;
  font-family: 'JetBrains Mono', 'Fira Code', ui-monospace, SFMono-Regular, Menlo, Monaco,
    Consolas, monospace;
  font-size: 0.85rem;
  letter-spacing: 0.04em;
}

.advanced {
  border: 1px dashed rgba(148, 163, 184, 0.3);
  border-radius: 12px;
  padding: 0.75rem 1rem;
  background: rgba(15, 23, 42, 0.45);
}

.advanced summary {
  cursor: pointer;
  font-size: 0.9rem;
  color: #cbd5f5;
}

.advanced[open] summary {
  margin-bottom: 0.85rem;
}

input:not([type='checkbox']) {
  height: 40px;
  border-radius: 10px;
  border: 1px solid rgba(148, 163, 184, 0.25);
  background: rgba(15, 23, 42, 0.9);
  padding: 0 0.75rem;
  color: #f8fafc;
}

input:not([type='checkbox']):focus {
  outline: none;
  border-color: #2563eb;
  box-shadow: 0 0 0 2px rgba(37, 99, 235, 0.35);
}

.actions {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 1rem;
  flex-wrap: wrap;
}

.primary-actions {
  display: flex;
  gap: 0.75rem;
  flex-wrap: wrap;
}

.auth-controls {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.auth-user {
  display: inline-flex;
  align-items: center;
  gap: 0.6rem;
}

.auth-user img,
.avatar-fallback {
  width: 32px;
  height: 32px;
  border-radius: 50%;
  border: 1px solid rgba(148, 163, 184, 0.4);
}

.avatar-fallback {
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(30, 41, 59, 0.8);
  color: #e2e8f0;
  font-weight: 600;
}

button {
  padding: 0.7rem 1.6rem;
  border-radius: 999px;
  border: none;
  background: linear-gradient(135deg, #2563eb, #38bdf8);
  color: #0f172a;
  font-weight: 600;
  cursor: pointer;
  transition: transform 0.15s ease, box-shadow 0.15s ease;
}

button:hover:not(:disabled) {
  transform: translateY(-1px);
  box-shadow: 0 10px 20px rgba(37, 99, 235, 0.25);
}

button:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

button.loading {
  position: relative;
  padding-right: 2.75rem;
}

button.loading::after {
  content: '';
  position: absolute;
  top: 50%;
  right: 1rem;
  width: 16px;
  height: 16px;
  margin-top: -8px;
  border-radius: 50%;
  border: 2px solid rgba(226, 232, 240, 0.8);
  border-top-color: transparent;
  animation: spin 0.8s linear infinite;
}

.ghost.loading {
  padding-right: 2.4rem;
}

.ghost.mini.loading {
  padding-right: 2rem;
}

.ghost.loading::after {
  border-color: rgba(148, 163, 184, 0.9);
  border-top-color: transparent;
}

.ghost.mini.loading::after {
  right: 0.75rem;
  width: 14px;
  height: 14px;
  margin-top: -7px;
}

.ghost {
  background: transparent;
  border: 1px solid rgba(148, 163, 184, 0.4);
  color: #e2e8f0;
}

.ghost.mini {
  padding: 0.35rem 1rem;
  font-size: 0.82rem;
  border-radius: 999px;
}

.personal-hint {
  margin: 0.5rem 0 0;
  font-size: 0.82rem;
  color: #fef08a;
}

@keyframes spin {
  0% {
    transform: rotate(0deg);
  }
  100% {
    transform: rotate(360deg);
  }
}

.status {
  margin: 0;
  font-size: 0.9rem;
}

.status.error {
  color: #fda4af;
}

.status.info {
  color: #bae6fd;
}

.status.warning {
  color: #fef08a;
}

.status-card .status + .status {
  margin-top: 0.35rem;
}

.status-card {
  background: rgba(30, 41, 59, 0.65);
  padding: 1.25rem;
  border-radius: 12px;
  border: 1px solid rgba(148, 163, 184, 0.2);
}

.status-card h2 {
  margin-top: 0;
}

.status-card p {
  margin: 0.4rem 0;
}

.status-card p:first-of-type {
  margin-top: 0.15rem;
}

.status-card p:last-of-type {
  margin-bottom: 0;
}

.status-card strong {
  margin-right: 0.5rem;
}

.link-button {
  background: none;
  border: none;
  padding: 0;
  color: inherit;
  font: inherit;
  text-decoration: underline;
  cursor: pointer;
}

.link-button:focus-visible {
  outline: 2px solid rgba(56, 189, 248, 0.9);
  outline-offset: 2px;
}

.badge {
  display: inline-flex;
  align-items: center;
  gap: 0.45rem;
  padding: 0.25rem 0.6rem;
  border-radius: 999px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  font-size: 0.75rem;
}

.badge-spinner {
  width: 0.85rem;
  height: 0.85rem;
  border-radius: 999px;
  border: 2px solid currentColor;
  border-top-color: transparent;
  animation: spin 0.9s linear infinite;
}

.badge.default {
  background: rgba(148, 163, 184, 0.2);
  color: #cbd5f5;
}

.badge.progress {
  background: rgba(56, 189, 248, 0.2);
  color: #bae6fd;
}

.badge.queued {
  background: rgba(253, 224, 71, 0.2);
  color: #facc15;
}

.badge.in-progress {
  background: rgba(129, 140, 248, 0.25);
  color: #c7d2fe;
}

.badge.success {
  background: rgba(74, 222, 128, 0.2);
  color: #bbf7d0;
}

.badge.error {
  background: rgba(248, 113, 113, 0.2);
  color: #fecaca;
}

.error-logs {
  margin-top: 1.5rem;
  padding: 1rem;
  border-radius: 8px;
  background: rgba(15, 23, 42, 0.8);
  border: 1px solid rgba(248, 113, 113, 0.3);
  max-width: 100%;
  box-sizing: border-box;
  overflow: hidden;
}

.error-logs h3 {
  margin: 0 0 0.75rem;
  font-size: 0.95rem;
  color: #fecaca;
}

.error-logs .loading-text {
  margin: 0;
  color: #94a3b8;
  font-size: 0.9rem;
}

.log-content {
  margin: 0;
  padding: 0.75rem;
  background: rgba(0, 0, 0, 0.4);
  border-radius: 6px;
  color: #f1f5f9;
  font-family: 'JetBrains Mono', 'Fira Code', ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas,
    monospace;
  font-size: 0.8rem;
  line-height: 1.5;
  overflow-x: auto;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 400px;
  overflow-y: auto;
  max-width: 100%;
  box-sizing: border-box;
}

.log-content::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}

.log-content::-webkit-scrollbar-track {
  background: rgba(15, 23, 42, 0.5);
  border-radius: 4px;
}

.log-content::-webkit-scrollbar-thumb {
  background: rgba(148, 163, 184, 0.5);
  border-radius: 4px;
}

.log-content::-webkit-scrollbar-thumb:hover {
  background: rgba(148, 163, 184, 0.7);
}
</style>
