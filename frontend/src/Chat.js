import React, { useState, useEffect, useRef, useCallback } from 'react';
import { fetchAuthSession } from 'aws-amplify/auth';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import './Chat.css';
import awsConfig from './aws-config';

const WS_URL = awsConfig.websocketUrl;
const PING_INTERVAL = 30000;

export default function Chat({ user, signOut }) {
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState('');

  const wsRef = useRef(null);
  const pingRef = useRef(null);
  const bottomRef = useRef(null);
  const chunkBufferRef = useRef('');
  const imageChunkBufferRef = useRef({});

  const appendMessage = useCallback((msg) => {
    setMessages((prev) => [...prev, msg]);
  }, []);

  const connect = useCallback(async () => {
    try {
      const session = await fetchAuthSession();
      const token = session.tokens?.idToken?.toString();
      if (!token) throw new Error('No auth token');

      const ws = new WebSocket(`${WS_URL}?token=${token}`);
      wsRef.current = ws;

      ws.onopen = () => {
        setConnected(true);
        setError('');
        pingRef.current = setInterval(() => {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ action: 'ping' }));
          }
        }, PING_INTERVAL);
      };

      ws.onclose = () => {
        setConnected(false);
        clearInterval(pingRef.current);
        setTimeout(connect, 3000);
      };

      ws.onerror = () => {
        setError('Connection interrupted — reconnecting...');
      };

      ws.onmessage = (event) => {
        const data = JSON.parse(event.data);

        if (data.type === 'pong') return;

        if (data.type === 'error') {
          setLoading(false);
          chunkBufferRef.current = '';
          appendMessage({ role: 'assistant', content: data.message || 'An error occurred.' });
          return;
        }

        // "thinking" — agent is processing, keep loading spinner
        if (data.type === 'thinking' || data.type === 'stream_start') {
          return;
        }

        // Ignore stream chunks — we wait for the final response
        if (data.type === 'stream') return;
        if (data.type === 'stream_end') return;

        // response_chunk — large response sent in pieces
        if (data.type === 'response_chunk') {
          chunkBufferRef.current += (data.chunk || '');
          if (data.is_last) {
            setLoading(false);
            appendMessage({
              role: 'assistant',
              content: chunkBufferRef.current,
              sql: data.sql || '',
              recordCount: data.record_count || 0,
            });
            chunkBufferRef.current = '';
          }
          return;
        }

        if (data.type === 'image') {
          // Attach image to last assistant message
          setMessages((prev) => {
            const updated = [...prev];
            const last = updated[updated.length - 1];
            if (last?.role === 'assistant') {
              updated[updated.length - 1] = {
                ...last,
                images: [...(last.images || []), data.image],
              };
            }
            return updated;
          });
          return;
        }

        if (data.type === 'image_chunk') {
          // Reassemble chunked image
          const idx = data.index || 0;
          if (!imageChunkBufferRef.current[idx]) {
            imageChunkBufferRef.current[idx] = '';
          }
          imageChunkBufferRef.current[idx] += (data.chunk || '');
          if (data.is_last) {
            const fullImage = imageChunkBufferRef.current[idx];
            delete imageChunkBufferRef.current[idx];
            setMessages((prev) => {
              const updated = [...prev];
              const last = updated[updated.length - 1];
              if (last?.role === 'assistant') {
                updated[updated.length - 1] = {
                  ...last,
                  images: [...(last.images || []), fullImage],
                };
              }
              return updated;
            });
          }
          return;
        }

        if (data.type === 'response') {
          setLoading(false);
          chunkBufferRef.current = '';
          appendMessage({
            role: 'assistant',
            content: data.response || '',
            sql: data.sql || '',
            recordCount: data.record_count || 0,
            images: data.images || [],
          });
        }
      };
    } catch (err) {
      setError(`Connection failed: ${err.message}`);
      setTimeout(connect, 5000);
    }
  }, [appendMessage]);

  useEffect(() => {
    connect();
    return () => {
      clearInterval(pingRef.current);
      wsRef.current?.close();
    };
  }, [connect]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, loading]);

  const sendMessage = async () => {
    const question = input.trim();
    if (!question || loading || !connected) return;

    setInput('');
    setLoading(true);
    appendMessage({ role: 'user', content: question });

    try {
      const session = await fetchAuthSession();
      const userId = user?.userId || user?.username || 'unknown';

      wsRef.current.send(
        JSON.stringify({
          action: 'sendMessage',
          question,
          userId,
          idToken: session.tokens?.idToken?.toString(),
        })
      );
    } catch (err) {
      setLoading(false);
      setError(`Send failed: ${err.message}`);
    }
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  const userEmail = user?.signInDetails?.loginId || user?.username || '';

  return (
    <div className="app-shell">
      {/* Sidebar */}
      <aside className="sidebar">
        <div className="sidebar-brand">
          <div className="brand-icon">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 2L2 7l10 5 10-5-10-5z"/>
              <path d="M2 17l10 5 10-5"/>
              <path d="M2 12l10 5 10-5"/>
            </svg>
          </div>
          <span className="brand-text">Cash Flow Analytics</span>
        </div>
        <nav className="sidebar-nav">
          <div className="nav-section-label">Analytics</div>
          <a className="nav-item active" href="#chat">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/></svg>
            AI Assistant
          </a>
        </nav>
        <div className="sidebar-footer">
          <div className="user-info">
            <div className="user-avatar">{userEmail.charAt(0).toUpperCase()}</div>
            <div className="user-details">
              <span className="user-name">{userEmail.split('@')[0]}</span>
              <span className="user-org">Oracle EBS</span>
            </div>
          </div>
          <button className="sign-out-link" onClick={signOut}>Sign out</button>
        </div>
      </aside>

      {/* Main content */}
      <main className="main-content">
        <header className="top-bar">
          <div className="top-bar-left">
            <h1 className="page-title">AI Assistant</h1>
            <span className={`conn-badge ${connected ? 'online' : 'offline'}`}>
              {connected ? 'Connected' : 'Reconnecting...'}
            </span>
          </div>
          <div className="top-bar-right">
            <span className="env-badge">Production</span>
          </div>
        </header>

        {error && <div className="alert-bar">{error}</div>}

        <div className="messages-area">
          {messages.length === 0 && !loading && (
            <div className="welcome-panel">
              <div className="welcome-icon">
                <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <circle cx="12" cy="12" r="10"/>
                  <path d="M12 6v6l4 2"/>
                </svg>
              </div>
              <h2>Oracle EBS Cash Flow Analytics</h2>
              <p>Ask questions about AR aging, overdue customers, cash flow trends, or take collections actions.</p>
              <div className="quick-actions">
                <button onClick={() => { setInput('Show me the current cash position'); }}>Cash Position</button>
                <button onClick={() => { setInput('Show me aging buckets'); }}>Aging Buckets</button>
                <button onClick={() => { setInput('Who are the top overdue customers?'); }}>Top Overdue</button>
                <button onClick={() => { setInput('What is our cash flow trend this month?'); }}>Cash Flow Trend</button>
              </div>
            </div>
          )}

          {messages.map((msg, i) => (
            <div key={i} className={`msg-row ${msg.role}`}>
              <div className="msg-avatar">
                {msg.role === 'assistant' ? (
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>
                ) : (
                  <span>{userEmail.charAt(0).toUpperCase()}</span>
                )}
              </div>
              <div className="msg-body">
                <div className="msg-meta">
                  <span className="msg-sender">{msg.role === 'assistant' ? 'AI Assistant' : userEmail.split('@')[0]}</span>
                </div>
                <div className="msg-content">
                  {msg.role === 'assistant' ? (
                    <ReactMarkdown remarkPlugins={[remarkGfm]}>{msg.content}</ReactMarkdown>
                  ) : (
                    <p>{msg.content}</p>
                  )}
                  {msg.sql && (
                    <details className="sql-details">
                      <summary>View SQL Query</summary>
                      <pre>{msg.sql}</pre>
                    </details>
                  )}
                  {msg.recordCount > 0 && (
                    <span className="record-badge">{msg.recordCount} records</span>
                  )}
                  {msg.images?.map((img, j) => (
                    <img key={j} src={img.startsWith('http') ? img : `data:image/png;base64,${img}`} alt={`Chart ${j + 1}`} className="chart-img" />
                  ))}
                </div>
              </div>
            </div>
          ))}

          {loading && (
            <div className="msg-row assistant">
              <div className="msg-avatar">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>
              </div>
              <div className="msg-body">
                <div className="msg-meta"><span className="msg-sender">AI Assistant</span></div>
                <div className="msg-content thinking">
                  <div className="thinking-dots"><span/><span/><span/></div>
                  <span className="thinking-text">Analyzing...</span>
                </div>
              </div>
            </div>
          )}
          <div ref={bottomRef} />
        </div>

        <div className="input-bar">
          <div className="input-wrapper">
            <textarea
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Ask about cash flow, AR aging, overdue customers..."
              rows={1}
              disabled={!connected || loading}
            />
            <button
              className="send-btn"
              onClick={sendMessage}
              disabled={!connected || loading || !input.trim()}
              aria-label="Send message"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/>
              </svg>
            </button>
          </div>
        </div>
      </main>
    </div>
  );
}
