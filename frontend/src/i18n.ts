import { createI18n } from 'vue-i18n';

export const LOCALE_STORAGE_KEY = 'arduino-online-compiler:locale';
export const SUPPORTED_LOCALES = ['en', 'zh'] as const;
export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];

const FALLBACK_LOCALE: SupportedLocale = 'en';

const messages = {
  en: {
    app: {
      title: 'Arduino Online Compiler',
      localeLabel: 'Language',
      locales: {
        en: 'English',
        zh: '中文'
      }
    },
    compileForm: {
      loading: 'Loading...',
      missingScopes:
        'The current authorization is missing the following scopes: {scopes}. Please sign out and authorize again.',
      fields: {
        ini: {
          label: 'platformio.ini',
          hint: 'PlatformIO project configuration. Only the espressif32 / espressif8266 platforms are supported, and the framework must be arduino.'
        },
        sketch: {
          label: 'src/main.cpp',
          hint: 'The Arduino sketch compiled by PlatformIO. Include <Arduino.h> and implement setup() and loop().'
        },
        artifactPassword: {
          label: 'Archive Password',
          placeholder: 'Auto-generated 16-character alphanumeric value',
          regenerate: 'Regenerate',
          hint: 'You will need this password to unzip the firmware artifact. Use 8-64 alphanumeric characters.'
        },
        pioVersion: {
          label: 'PlatformIO Core Version',
          placeholder: 'e.g. 6.1.18 (leave empty for latest)',
          hint: 'Optional. Pin the PlatformIO Core version for reproducible builds.'
        }
      },
      advanced: {
        summary: 'Advanced options'
      },
      actions: {
        submitting: 'Submitting...',
        submit: 'Start compilation',
        reset: 'Reset'
      },
      auth: {
        avatarAlt: 'User avatar',
        logout: 'Sign out',
        login: 'Authorize with personal GitHub',
        encouragePersonal:
          'The platform GitHub authorization is unavailable right now. Please continue with your personal GitHub.'
      },
      submitHints: {
        loginRequired: 'Please authorize with GitHub before submitting a build.',
        missingScopes:
          'Your GitHub authorization is missing the workflow/public_repo permissions. Please re-authorize.'
      },
      status: {
        sectionTitle: 'Compilation Status',
        requestId: 'Request ID:',
        runId: 'Workflow Run ID:',
        currentStatus: 'Current status:',
        runLinkLabel: 'GitHub Workflow:',
        openRun: 'Open',
        pioVersion: 'PlatformIO version:',
        artifactPassword: 'Archive password:',
        artifact: 'Firmware artifact:',
        downloading: 'Downloading...',
        downloadArtifact: 'Download {name}.zip',
        workflowQueued: 'Workflow triggered. Waiting to run...',
        errorLogs: 'Error Logs',
        loadingLogs: 'Loading error logs...'
      },
      statusDisplay: {
        notStarted: 'Not started',
        completed: 'Completed',
        status: {
          queued: 'Queued',
          in_progress: 'In progress',
          waiting: 'Waiting',
          pending: 'Pending',
          requested: 'Requested'
        },
        conclusion: {
          success: 'Succeeded',
          failure: 'Failed',
          cancelled: 'Cancelled',
          timed_out: 'Timed out',
          neutral: 'Neutral',
          skipped: 'Skipped',
          action_required: 'Action required',
          stale: 'Stale',
          startup_failure: 'Startup failure'
        }
      },
      errors: {
        iniRequired: 'Please provide the platformio.ini content.',
        sketchRequired: 'Please provide the src/main.cpp content.',
        iniTooLarge: 'platformio.ini is too large. Keep it under 24KB.',
        sketchTooLarge: 'src/main.cpp is too large. Keep it under 64KB.',
        loginRequired: 'Please sign in with GitHub before submitting a build.',
        missingScopes:
          'Your GitHub authorization is missing required permissions. Please re-authorize.',
        pioVersionInvalid:
          'PlatformIO version must look like 6.1.18 (three numeric parts).',
        passwordRequired: 'Set a password for decrypting the artifact.',
        passwordLength: 'The password must be between 8 and 64 characters.',
        passwordCharset: 'The password may only contain letters and numbers.',
        triggerFailed: 'Failed to trigger the workflow. Please try again later.',
        statusFailed: 'Failed to refresh the workflow status.',
        downloadFailed:
          'Failed to download the firmware. Check your permissions or try again later.'
      }
    }
  },
  zh: {
    app: {
      title: 'Arduino 在线编译',
      localeLabel: '语言',
      locales: {
        en: '英语',
        zh: '中文'
      }
    },
    compileForm: {
      loading: '正在加载...',
      missingScopes: '当前授权缺少以下 scope：{scopes}，请退出后重新授权。',
      fields: {
        ini: {
          label: 'platformio.ini',
          hint: 'PlatformIO 工程配置。当前仅支持 espressif32 / espressif8266 平台，且 framework 必须为 arduino。'
        },
        sketch: {
          label: 'src/main.cpp',
          hint: '交由 PlatformIO 编译的 Arduino 源码，需要 #include <Arduino.h> 并实现 setup() 与 loop()。'
        },
        artifactPassword: {
          label: '压缩包密码',
          placeholder: '自动生成 16 位字母数字组合',
          regenerate: '重新生成',
          hint: '下载固件产物后需要该密码才能解压，建议使用 8-64 位字母或数字组合。'
        },
        pioVersion: {
          label: 'PlatformIO Core 版本',
          placeholder: '例如 6.1.18（留空使用最新版）',
          hint: '可选。锁定 PlatformIO Core 版本可以让编译结果更可复现。'
        }
      },
      advanced: {
        summary: '高级选项'
      },
      actions: {
        submitting: '正在提交...',
        submit: '提交编译',
        reset: '重置'
      },
      auth: {
        avatarAlt: '用户头像',
        logout: '退出',
        login: '个人 GitHub 授权',
        encouragePersonal: '平台 GitHub 授权当前不可用，请使用个人 GitHub 授权继续编译。'
      },
      submitHints: {
        loginRequired: '请先完成 GitHub 授权后再提交编译。',
        missingScopes: '当前 GitHub 授权缺少 workflow/public_repo 权限，请重新授权后再试。'
      },
      status: {
        sectionTitle: '编译状态',
        requestId: '请求 ID:',
        runId: 'Workflow Run ID:',
        currentStatus: '当前状态:',
        runLinkLabel: 'GitHub Workflow:',
        openRun: '打开',
        pioVersion: 'PlatformIO 版本:',
        artifactPassword: '解压密码:',
        artifact: '固件产物:',
        downloading: '下载中...',
        downloadArtifact: '下载 {name}.zip',
        workflowQueued: 'Workflow 已触发，等待运行...',
        errorLogs: '错误日志',
        loadingLogs: '正在获取错误日志...'
      },
      statusDisplay: {
        notStarted: '尚未开始',
        completed: '完成',
        status: {
          queued: '排队中',
          in_progress: '编译中',
          waiting: '等待中',
          pending: '待处理',
          requested: '已请求'
        },
        conclusion: {
          success: '成功',
          failure: '失败',
          cancelled: '已取消',
          timed_out: '超时',
          neutral: '中性',
          skipped: '已跳过',
          action_required: '需要人工处理',
          stale: '已过期',
          startup_failure: '启动失败'
        }
      },
      errors: {
        iniRequired: '请填写 platformio.ini 内容。',
        sketchRequired: '请填写 src/main.cpp 内容。',
        iniTooLarge: 'platformio.ini 内容过大，请控制在 24KB 以内。',
        sketchTooLarge: 'src/main.cpp 内容过大，请控制在 64KB 以内。',
        loginRequired: '请先完成 GitHub 授权后再提交编译。',
        missingScopes: '当前 GitHub 授权缺少必要权限，请重新授权后再试。',
        pioVersionInvalid: 'PlatformIO 版本号格式不正确，应形如 6.1.18。',
        passwordRequired: '请设置用于解压产物的密码。',
        passwordLength: '密码长度需在 8 到 64 个字符之间。',
        passwordCharset: '密码仅支持字母与数字。',
        triggerFailed: '触发编译失败，请稍后重试。',
        statusFailed: '刷新编译状态失败。',
        downloadFailed: '下载固件失败，请检查权限或稍后重试。'
      }
    }
  }
};

function detectInitialLocale(): SupportedLocale {
  if (typeof window === 'undefined') {
    return FALLBACK_LOCALE;
  }
  try {
    const stored = window.localStorage.getItem(LOCALE_STORAGE_KEY);
    if (stored && SUPPORTED_LOCALES.includes(stored as SupportedLocale)) {
      return stored as SupportedLocale;
    }
  } catch (err) {
    console.warn('Failed to restore locale', err);
  }
  const navigatorLang =
    typeof navigator !== 'undefined' ? navigator.language ?? '' : '';
  return navigatorLang.toLowerCase().startsWith('zh') ? 'zh' : FALLBACK_LOCALE;
}

export function persistLocale(locale: SupportedLocale) {
  if (typeof window === 'undefined') {
    return;
  }
  try {
    window.localStorage.setItem(LOCALE_STORAGE_KEY, locale);
  } catch (err) {
    console.warn('Failed to persist locale', err);
  }
}

export const i18n = createI18n({
  legacy: false,
  locale: detectInitialLocale(),
  fallbackLocale: FALLBACK_LOCALE,
  messages
});
