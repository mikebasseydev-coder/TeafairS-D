import { z } from "zod";

/** The email step's input, normalised before it is sent. */
export const emailSchema = z
  .string()
  .trim()
  .toLowerCase()
  .pipe(z.email({ message: "Enter a valid email address." }));

export const codeSchema = z.string().regex(/^\d{6}$/, { message: "The code is six digits." });
