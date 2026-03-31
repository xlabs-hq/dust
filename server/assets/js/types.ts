export interface User {
  id: string;
  email: string;
  name: string | null;
}

export interface Organization {
  id: string;
  name: string;
  slug: string;
}

export interface SharedProps {
  current_user: User | null;
  current_organization: Organization | null;
  user_organizations: Organization[];
  flash: { info: string | null; error: string | null };
  [key: string]: unknown;
}
