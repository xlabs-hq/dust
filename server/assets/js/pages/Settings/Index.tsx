import React from "react";
import { Head, usePage } from "@inertiajs/react";
import { Badge } from "@/components/ui/Badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/Card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/Table";
import type { SharedProps } from "@/types";

interface Member {
  id: string;
  email: string;
  name: string | null;
  role: string;
  inserted_at: string;
}

interface SettingsProps extends SharedProps {
  organization: {
    id: string;
    name: string;
    slug: string;
    inserted_at: string;
  };
  members: Member[];
}

export default function SettingsIndex() {
  const { organization, members } = usePage<SettingsProps>().props;

  return (
    <>
      <Head title="Settings" />
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-foreground">
            Settings
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Organization settings and membership
          </p>
        </div>

        <Card>
          <CardHeader>
            <CardTitle>Organization</CardTitle>
            <CardDescription>
              Basic information about your organization
            </CardDescription>
          </CardHeader>
          <CardContent>
            <dl className="grid grid-cols-[auto_1fr] gap-x-8 gap-y-3 text-sm">
              <dt className="text-muted-foreground">Name</dt>
              <dd className="font-medium">{organization.name}</dd>
              <dt className="text-muted-foreground">Slug</dt>
              <dd className="font-mono">{organization.slug}</dd>
              <dt className="text-muted-foreground">Created</dt>
              <dd>{formatDate(organization.inserted_at)}</dd>
            </dl>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Members</CardTitle>
            <CardDescription>
              People with access to this organization
            </CardDescription>
          </CardHeader>
          <CardContent className="p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Email</TableHead>
                  <TableHead>Name</TableHead>
                  <TableHead>Role</TableHead>
                  <TableHead>Joined</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {members.map((member) => (
                  <TableRow key={member.id}>
                    <TableCell className="font-medium">
                      {member.email}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {member.name || "--"}
                    </TableCell>
                    <TableCell>
                      <RoleBadge role={member.role} />
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {formatDate(member.inserted_at)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      </div>
    </>
  );
}

function RoleBadge({ role }: { role: string }) {
  const variant = role === "owner" ? "default" : role === "admin" ? "secondary" : "outline";
  return <Badge variant={variant}>{role}</Badge>;
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}
