import { z } from "zod";
import { TENANT_ROLES } from "@/shared/tokens";

export const tenantRoleSchema = z.enum(TENANT_ROLES);

export const invitationSchema = z.object({
  tenant_user_id: z.string(),
  tenant_id: z.string(),
  tenant_name: z.string(),
  tenant_code: z.string(),
  role: tenantRoleSchema,
  zone_name: z.string().nullable(),
  territory_name: z.string().nullable(),
  area_name: z.string().nullable(),
  invited_at: z.string(),
});
export type Invitation = z.infer<typeof invitationSchema>;

export const pinStatusSchema = z.object({
  tenant_user_id: z.string(),
  pin_set: z.boolean(),
  locked_until: z.string().nullable(),
});
export type PinStatus = z.infer<typeof pinStatusSchema>;

export const pinChangeReplySchema = z.object({
  changed: z.boolean(),
  attempts_remaining: z.number(),
  locked_until: z.string().nullable(),
});
export type PinChangeReply = z.infer<typeof pinChangeReplySchema>;

export const pinCheckSchema = z.object({
  ok: z.boolean().nullable(),
  attempts_left: z.number().nullable(),
  locked_until: z.string().nullable(),
});
export type PinCheck = z.infer<typeof pinCheckSchema>;

export type Membership = { tenantUserId: string; tenantId: string; code: string; name: string; role: z.infer<typeof tenantRoleSchema> };

/** Where the signed-in person goes next (Spec B §9.3). */
export type AccessRoute = "sign-in" | "pin" | "onboarding" | "agent" | "use-web" | "no-access";
