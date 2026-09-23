import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { signup } from "../api";

export function SignupPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    setMessage(null);
    try {
      const user = await signup({
        email,
        password,
        display_name: displayName || undefined,
      });
      setMessage(`Account created for ${user.email} (id ${user.id})`);
      setEmail("");
      setPassword("");
      setDisplayName("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "signup failed");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="page">
      <h1>Sign up</h1>
      <p className="muted">Phase 0 — local API</p>
      <form onSubmit={onSubmit} className="card">
        <label>
          Email
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </label>
        <label>
          Password (min 8 chars)
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            minLength={8}
            required
          />
        </label>
        <label>
          Display name (optional)
          <input
            type="text"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
          />
        </label>
        <button type="submit" disabled={loading}>
          {loading ? "Creating…" : "Create account"}
        </button>
      </form>
      {message && <p className="success">{message}</p>}
      {error && <p className="error">{error}</p>}
      <p>
        <Link to="/admin">Admin → user list</Link>
      </p>
    </div>
  );
}
