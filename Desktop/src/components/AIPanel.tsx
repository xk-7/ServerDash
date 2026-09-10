import { useEffect, useRef, useState } from 'react';
import { Bot, Plus, Settings2, Square } from 'lucide-react';
import { desktopAvailable, errorMessage, onDesktopEvent, request, type SessionRef } from '../lib/api';
import { terminalContext } from '../lib/terminalRegistry';
import { Dialog } from './Dialog';

const providers = [
  ['openAI', 'OpenAI', 'https://api.openai.com/v1'], ['anthropic', 'Anthropic', 'https://api.anthropic.com/v1'],
  ['gemini', 'Gemini', 'https://generativelanguage.googleapis.com/v1beta'], ['deepSeek', 'DeepSeek', 'https://api.deepseek.com/v1'],
  ['qwen', '通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1'], ['volcengine', '火山引擎', 'https://ark.cn-beijing.volces.com/api/v3'],
  ['ollama', 'Ollama', 'http://localhost:11434'], ['custom', '兼容 OpenAI API', 'https://api.example.com/v1'],
];
type Profile = { id: string; name?: string; provider: string; baseURL: string; model: string; credentialId?: string };
type Message = { role: string; content: string };
type Conversation = { id: string; name: string; profileId: string; messages: Message[]; target?: SessionRef };
const initialProfile = (): Profile => ({ id: crypto.randomUUID(), provider: 'openAI', baseURL: providers[0][2], model: '' });

export default function AIPanel({ enabled, session, onError }: { enabled: boolean; session?: SessionRef; onError: (message: string) => void }) {
  const [profiles, setProfiles] = useState<Profile[]>([]); const [profileId, setProfileId] = useState('');
  const [conversations, setConversations] = useState<Conversation[]>([]); const [conversation, setConversation] = useState<Conversation>();
  const [messages, setMessages] = useState<Message[]>([]); const [response, setResponse] = useState(''); const [prompt, setPrompt] = useState('');
  const [busy, setBusy] = useState(false); const [shareContext, setShareContext] = useState(false); const [command, setCommand] = useState<string>();
  const [editor, setEditor] = useState<Profile>(); const [apiKey, setApiKey] = useState(''); const [saving, setSaving] = useState(false);
  const [models, setModels] = useState<{ id: string; name: string }[]>([]);
  const selected = useRef<Conversation | undefined>(undefined); selected.current = conversation;
  const running = useRef(false); const requestId = useRef(''); const errors = useRef(onError); errors.current = onError;
  const mounted = useRef(true); const cancelPending = useRef(false);
  const refresh = async () => { if (!desktopAvailable()) return; try { const [p, c] = await Promise.all([request<Profile[]>('ai_profile_list'), request<Conversation[]>('ai_conversation_list')]); setProfiles(p); setProfileId(id => id || p[0]?.id || ''); setConversations(c); } catch (e) { errors.current(errorMessage(e)); } };
  useEffect(() => { void refresh(); }, []);
  useEffect(() => {
    let alive = true; let stop: (() => void) | undefined; mounted.current = true;
    void onDesktopEvent(event => {
      if (event.kind as string !== 'ai') return;
      const payload = event.payload as unknown as { conversationId: string; requestId: string; text?: string; done?: boolean; error?: string };
      if (payload.conversationId !== selected.current?.id) return;
      if (payload.text) setResponse(value => value + payload.text);
      if (payload.done) {
        running.current = false; requestId.current = ''; setBusy(false);
        if (payload.error) errors.current(payload.error);
        void request<Conversation>('ai_conversation_get', { id: payload.conversationId }).then(c => { if (alive && selected.current?.id === c.id) { setConversation(c); setMessages(c.messages); setResponse(''); } }).catch(e => errors.current(errorMessage(e)));
        void refresh();
      }
    }).then(unlisten => { if (alive) stop = unlisten; else unlisten(); }).catch(e => { if (alive) errors.current(errorMessage(e)); });
    return () => { alive = false; mounted.current = false; cancelPending.current = true; stop?.(); if (requestId.current) void request('ai_cancel', { requestId: requestId.current }).catch(() => {}); };
  }, []);
  useEffect(() => { setShareContext(false); }, [session?.sessionId, session?.generation]);
  const send = async () => {
    if (running.current || !prompt.trim()) return;
    const content = prompt.trim(); const c = conversation ?? { id: crypto.randomUUID(), name: content.slice(0, 40), profileId, messages: [], target: session };
    selected.current = c; setConversation(c); running.current = true; cancelPending.current = false; setBusy(true); setResponse('');
    try {
      let context: string | undefined;
      if (shareContext && session) { if (c.target?.sessionId !== session.sessionId || c.target?.generation !== session.generation) throw new Error("当前连接已改变，请新建对话"); await request('ai_context_authorize', { ...session, enabled: true }); context = terminalContext(session); }
      if (!mounted.current || cancelPending.current) { running.current = false; if (mounted.current) setBusy(false); return; }
      const result = await request<{ requestId: string }>('ai_send', { profileId: c.profileId, conversationId: c.id, message: content, target: c.target, context });
      if (!mounted.current || cancelPending.current) { await request('ai_cancel', { requestId: result.requestId }); return; }
      if (running.current) { requestId.current = result.requestId; setMessages(old => [...old, { role: 'user', content }]); }
      setPrompt('');
    } catch (e) { running.current = false; setBusy(false); onError(errorMessage(e)); }
  };
  const cancel = () => { cancelPending.current = true; if (requestId.current) void request('ai_cancel', { requestId: requestId.current }).catch(e => onError(errorMessage(e))); };
  const changeConversation = (id: string) => { const c = conversations.find(item => item.id === id); setConversation(c); selected.current = c; setMessages(c?.messages ?? []); setResponse(''); setShareContext(false); if (c) setProfileId(c.profileId); };
  const saveProfile = async () => {
    if (!editor) return; setSaving(true);
    try { const saved = await request<Profile>('ai_profile_save', { profile: editor, apiKey }); setApiKey(''); setEditor(undefined); setProfileId(saved.id); changeConversation(''); await refresh(); }
    catch (e) { onError(errorMessage(e)); } finally { setSaving(false); }
  };
  const execute = async () => {
    if (!conversation || !command) return;
    try { await request('ai_execute', { conversationId: conversation.id, target: conversation.target, command, confirmed: true }); setCommand(undefined); }
    catch (e) { onError(errorMessage(e)); }
  };
  return <div className="ai-panel"><div className="panel-title"><h3><Bot size={17} />AI 助手</h3><button className="icon-button" disabled={busy} aria-label="配置 AI 提供商" onClick={() => { setEditor(profiles.find(p => p.id === profileId) ?? initialProfile()); setApiKey(''); }}><Settings2 size={16} /></button><button className="icon-button" disabled={busy} aria-label="新建对话" onClick={() => changeConversation('')}><Plus size={16} /></button></div>
    <select aria-label="AI 提供商配置" disabled={busy || !!conversation} value={profileId} onChange={e => setProfileId(e.target.value)}><option value="">选择提供商</option>{profiles.map(p => <option key={p.id} value={p.id}>{p.name || p.provider} · {p.model}</option>)}</select>
    <select aria-label="本地对话" disabled={busy} value={conversation?.id ?? ''} onChange={e => changeConversation(e.target.value)}><option value="">新对话</option>{conversations.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
    <div className="ai-messages">{[...messages, ...(response ? [{ role: 'assistant', content: response }] : [])].map((message, index) => <div className={`ai-message ${message.role}`} key={index}><small>{message.role === 'user' ? '你' : '助手'}</small><p>{message.content}</p>{message.role === 'assistant' && conversation?.target && !busy && Array.from(message.content.matchAll(/```(?:bash|sh|shell|zsh)?\n([^\n`]+)\n```/g)).map((match, i) => <button key={i} onClick={() => setCommand(match[1])}>检查并发送命令</button>)}</div>)}{!messages.length && !response && <p className="subtle">配置模型后开始对话。分享上下文前请检查终端中是否包含敏感信息。</p>}</div>
    <form onSubmit={e => { e.preventDefault(); void send(); }}><label className="checkbox-label"><input type="checkbox" disabled={busy || !session || (!!conversation && JSON.stringify(conversation.target) !== JSON.stringify(session))} checked={shareContext} onChange={e => { setShareContext(e.target.checked); if (!e.target.checked && session) void request('ai_context_authorize', { ...session, enabled: false }).catch(() => {}); }} />本次附加原连接的最近终端输出</label><textarea aria-label="发送给 AI 的问题" placeholder="描述你的问题…" disabled={!enabled} value={prompt} onChange={e => setPrompt(e.target.value)} rows={3} /><div className="toolbar-actions">{busy && <button type="button" onClick={cancel}><Square size={13} />停止</button>}<button className="primary" disabled={!enabled || busy || !profileId || !prompt.trim()}>发送</button></div></form>
    {editor && <Dialog title="AI 提供商" onClose={() => { setEditor(undefined); setApiKey(''); }}><div className="form-grid"><label>提供商<select value={editor.provider} onChange={e => setEditor({ ...editor, provider: e.target.value, baseURL: providers.find(p => p[0] === e.target.value)![2], model: '' })}>{providers.map(p => <option key={p[0]} value={p[0]}>{p[1]}</option>)}</select></label><label>名称<input value={editor.name ?? ''} onChange={e => setEditor({ ...editor, name: e.target.value })} /></label><label className="full-width">API 地址<input value={editor.baseURL} onChange={e => setEditor({ ...editor, baseURL: e.target.value })} /></label><label className="full-width">API 密钥<input type="password" autoComplete="off" placeholder={editor.credentialId ? '已保存；留空保留' : '输入密钥'} value={apiKey} onChange={e => setApiKey(e.target.value)} /></label><label className="full-width">模型<input list="ai-models" value={editor.model} onChange={e => setEditor({ ...editor, model: e.target.value })} /><datalist id="ai-models">{models.map(m => <option key={m.id} value={m.id}>{m.name}</option>)}</datalist></label></div><div className="dialog-actions"><button onClick={() => { setEditor(initialProfile()); setApiKey(''); }}>新增配置</button><button disabled={!editor.credentialId} onClick={() => void request<{ id: string; name: string }[]>('ai_models', { profileId: editor.id }).then(setModels).catch(e => onError(errorMessage(e)))}>读取已保存配置的模型</button><button className="primary" disabled={saving || !editor.model.trim()} onClick={() => void saveProfile()}>保存</button></div></Dialog>}
    {command && <Dialog title="确认发送到原 SSH 连接" onClose={() => setCommand(undefined)}><p>连接：<code>{conversation?.target?.sessionId}</code> · 代次 {conversation?.target?.generation}</p><pre className="command-confirm">{command}</pre><p>命令会发送并执行；连接结束后此确认自动失效。</p><div className="dialog-actions"><button onClick={() => setCommand(undefined)}>取消</button><button className="primary" onClick={() => void execute()}>发送并执行</button></div></Dialog>}
  </div>;
}
