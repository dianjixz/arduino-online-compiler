<template>
  <div
    ref="editorContainer"
    class="code-editor"
    :class="`code-editor--${language}`"
  ></div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { EditorState } from '@codemirror/state';
import {
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
  placeholder as placeholderExtension
} from '@codemirror/view';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import {
  HighlightStyle,
  StreamLanguage,
  bracketMatching,
  syntaxHighlighting
} from '@codemirror/language';
import { closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete';
import { cpp } from '@codemirror/lang-cpp';
import { properties } from '@codemirror/legacy-modes/mode/properties';
import { tags } from '@lezer/highlight';

const props = withDefaults(
  defineProps<{
    modelValue: string;
    language?: 'cpp' | 'ini';
    placeholder?: string;
  }>(),
  {
    language: 'cpp',
    placeholder: ''
  }
);

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
}>();

const editorContainer = ref<HTMLDivElement | null>(null);
let editorView: EditorView | null = null;

const minContentHeight = props.language === 'ini' ? '190px' : '340px';

const customTheme = EditorView.theme(
  {
    '&': {
      backgroundColor: 'rgba(15, 23, 42, 0.9)',
      fontSize: '13.5px',
      fontFamily:
        "'JetBrains Mono', 'Fira Code', ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
    },
    '.cm-content': {
      caretColor: '#38bdf8',
      minHeight: minContentHeight,
      padding: '0.75rem'
    },
    '.cm-cursor, .cm-dropCursor': {
      borderLeftColor: '#38bdf8'
    },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
      backgroundColor: 'rgba(56, 189, 248, 0.25)'
    },
    '.cm-activeLine': {
      backgroundColor: 'rgba(30, 41, 59, 0.5)'
    },
    '.cm-selectionMatch': {
      backgroundColor: 'rgba(56, 189, 248, 0.2)'
    },
    '.cm-gutters': {
      backgroundColor: 'rgba(15, 23, 42, 0.9)',
      color: '#64748b',
      border: 'none'
    },
    '.cm-activeLineGutter': {
      backgroundColor: 'rgba(30, 41, 59, 0.5)',
      color: '#94a3b8'
    },
    '.cm-lineNumbers .cm-gutterElement': {
      padding: '0 8px 0 5px',
      minWidth: '40px'
    },
    '.cm-scroller': {
      overflow: 'auto',
      scrollbarWidth: 'thin',
      scrollbarColor: 'rgba(148, 163, 184, 0.6) transparent'
    },
    '.cm-scroller::-webkit-scrollbar': {
      width: '8px',
      height: '8px'
    },
    '.cm-scroller::-webkit-scrollbar-track': {
      background: 'transparent'
    },
    '.cm-scroller::-webkit-scrollbar-thumb': {
      borderRadius: '12px',
      background: 'linear-gradient(135deg, rgba(37, 99, 235, 0.65), rgba(56, 189, 248, 0.65))'
    },
    '.cm-scroller::-webkit-scrollbar-thumb:hover': {
      background: 'linear-gradient(135deg, rgba(37, 99, 235, 0.85), rgba(56, 189, 248, 0.85))'
    }
  },
  { dark: true }
);

const customHighlighting = HighlightStyle.define([
  { tag: tags.keyword, color: '#c792ea' },
  { tag: tags.atom, color: '#f78c6c' },
  { tag: tags.number, color: '#f78c6c' },
  { tag: tags.string, color: '#a5d6a7' },
  { tag: tags.special(tags.string), color: '#a5d6a7' },
  { tag: tags.propertyName, color: '#82aaff' },
  { tag: tags.variableName, color: '#eeffff' },
  { tag: tags.typeName, color: '#ffcb6b' },
  { tag: tags.comment, color: '#546e7a', fontStyle: 'italic' },
  { tag: tags.bool, color: '#f78c6c' },
  { tag: tags.null, color: '#f78c6c' },
  { tag: tags.punctuation, color: '#89ddff' },
  { tag: tags.bracket, color: '#89ddff' },
  { tag: tags.operator, color: '#89ddff' },
  { tag: tags.meta, color: '#89ddff' },
  { tag: tags.tagName, color: '#f07178' },
  { tag: tags.attributeName, color: '#c792ea' }
]);

function buildLanguageExtension() {
  if (props.language === 'ini') {
    return StreamLanguage.define(properties);
  }
  return cpp();
}

onMounted(() => {
  if (!editorContainer.value) {
    return;
  }

  const extensions = [
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightActiveLine(),
    history(),
    bracketMatching(),
    closeBrackets(),
    syntaxHighlighting(customHighlighting),
    keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap]),
    buildLanguageExtension(),
    customTheme,
    EditorView.lineWrapping,
    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        emit('update:modelValue', update.state.doc.toString());
      }
    })
  ];

  if (props.placeholder) {
    extensions.push(placeholderExtension(props.placeholder));
  }

  editorView = new EditorView({
    state: EditorState.create({
      doc: props.modelValue,
      extensions
    }),
    parent: editorContainer.value
  });
});

// 外部（重置、草稿恢复）修改内容时同步进编辑器
watch(
  () => props.modelValue,
  (newValue) => {
    if (!editorView) {
      return;
    }
    const currentValue = editorView.state.doc.toString();
    if (currentValue !== newValue) {
      editorView.dispatch({
        changes: {
          from: 0,
          to: currentValue.length,
          insert: newValue
        }
      });
    }
  }
);

onBeforeUnmount(() => {
  if (editorView) {
    editorView.destroy();
    editorView = null;
  }
});
</script>

<style scoped>
.code-editor {
  width: 100%;
  border-radius: 12px;
  overflow: hidden;
  border: 1px solid rgba(148, 163, 184, 0.25);
}

.code-editor:focus-within {
  border-color: #2563eb;
  box-shadow: 0 0 0 2px rgba(37, 99, 235, 0.35);
}
</style>
