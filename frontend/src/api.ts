const API_BASE = import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8080";
const ADMIN_KEY = import.meta.env.VITE_ADMIN_API_KEY ?? "dev-admin-key-change-me";

export type User = {
  id: number;
  email: string;
  display_name?: string | null;
  created_at: string;
};

export type UserListResponse = {
  users: User[];
  page: number;
  limit: number;
  total: number;
  total_pages: number;
};

export async function signup(body: {
  email: string;
  password: string;
  display_name?: string;
}): Promise<User> {
  const res = await fetch(`${API_BASE}/api/v1/signup`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(data.error ?? "signup failed");
  }
  return data;
}

export async function listUsers(page: number, limit: number): Promise<UserListResponse> {
  const res = await fetch(
    `${API_BASE}/api/v1/users?page=${page}&limit=${limit}`,
    {
      headers: { "X-Admin-Key": ADMIN_KEY },
    }
  );
  const data = await res.json();
  if (!res.ok) {
    throw new Error(data.error ?? "failed to load users");
  }
  return data;
}
