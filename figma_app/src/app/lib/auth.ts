const AUTH_KEY = 'field:auth';

export interface AuthSession {
  phone: string;
  name: string;
  createdAt: string;
}

export function getSession(): AuthSession | null {
  try {
    const raw = localStorage.getItem(AUTH_KEY);
    return raw ? (JSON.parse(raw) as AuthSession) : null;
  } catch {
    return null;
  }
}

export function setSession(session: AuthSession) {
  localStorage.setItem(AUTH_KEY, JSON.stringify(session));
}

export function clearSession() {
  localStorage.removeItem(AUTH_KEY);
}

export function isAuthenticated(): boolean {
  return getSession() !== null;
}
