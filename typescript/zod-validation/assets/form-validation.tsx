// form-validation.tsx — React Hook Form + Zod integration template
//
// Usage: Copy and adapt for your project's forms.
// Dependencies: npm install react-hook-form @hookform/resolvers zod

import React from "react";
import { useForm, useFieldArray, type FieldErrors, type Path, type UseFormRegister } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";

// ─── Schema Definition ──────────────────────────────────────────────────────

const ContactSchema = z.object({
  firstName: z.string().trim().min(1, "First name is required").max(50),
  lastName: z.string().trim().min(1, "Last name is required").max(50),
  email: z.string().trim().toLowerCase().email("Invalid email address"),
  phone: z
    .string()
    .regex(/^\+?[\d\s()-]{7,20}$/, "Invalid phone number")
    .optional()
    .or(z.literal("")),
  company: z.string().max(100).optional(),
  role: z.enum(["developer", "designer", "manager", "other"], {
    errorMap: () => ({ message: "Please select a role" }),
  }),
  experience: z.coerce
    .number({ invalid_type_error: "Must be a number" })
    .int("Must be a whole number")
    .min(0, "Cannot be negative")
    .max(50, "Must be 50 or less"),
  skills: z
    .array(z.object({ name: z.string().min(1, "Skill name required") }))
    .min(1, "Add at least one skill")
    .max(10, "Maximum 10 skills"),
  bio: z.string().max(500, "Bio must be under 500 characters").optional(),
  newsletter: z.boolean().default(false),
  terms: z.literal(true, {
    errorMap: () => ({ message: "You must accept the terms and conditions" }),
  }),
});

type ContactFormData = z.infer<typeof ContactSchema>;

// ─── Reusable Field Components ──────────────────────────────────────────────

interface FormFieldProps<T extends Record<string, any>> {
  name: Path<T>;
  label: string;
  register: UseFormRegister<T>;
  errors: FieldErrors<T>;
  type?: string;
  placeholder?: string;
  required?: boolean;
}

function FormField<T extends Record<string, any>>({
  name,
  label,
  register,
  errors,
  type = "text",
  placeholder,
  required,
}: FormFieldProps<T>) {
  const error = name.split(".").reduce((acc: any, key) => acc?.[key], errors);

  return (
    <div className="form-field">
      <label htmlFor={name}>
        {label}
        {required && <span className="required" aria-hidden="true"> *</span>}
      </label>
      <input
        id={name}
        type={type}
        placeholder={placeholder}
        {...register(name)}
        aria-invalid={!!error}
        aria-describedby={error ? `${name}-error` : undefined}
      />
      {error && (
        <p id={`${name}-error`} className="error" role="alert">
          {(error as any)?.message}
        </p>
      )}
    </div>
  );
}

interface SelectFieldProps<T extends Record<string, any>> {
  name: Path<T>;
  label: string;
  register: UseFormRegister<T>;
  errors: FieldErrors<T>;
  options: { value: string; label: string }[];
  required?: boolean;
}

function SelectField<T extends Record<string, any>>({
  name,
  label,
  register,
  errors,
  options,
  required,
}: SelectFieldProps<T>) {
  const error = name.split(".").reduce((acc: any, key) => acc?.[key], errors);

  return (
    <div className="form-field">
      <label htmlFor={name}>
        {label}
        {required && <span className="required" aria-hidden="true"> *</span>}
      </label>
      <select
        id={name}
        {...register(name)}
        aria-invalid={!!error}
        aria-describedby={error ? `${name}-error` : undefined}
      >
        <option value="">Select...</option>
        {options.map((opt) => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
      </select>
      {error && (
        <p id={`${name}-error`} className="error" role="alert">
          {(error as any)?.message}
        </p>
      )}
    </div>
  );
}

// ─── Main Form Component ────────────────────────────────────────────────────

export function ContactForm() {
  const {
    register,
    handleSubmit,
    control,
    watch,
    reset,
    formState: { errors, isSubmitting, isSubmitSuccessful, isDirty },
  } = useForm<ContactFormData>({
    resolver: zodResolver(ContactSchema),
    defaultValues: {
      firstName: "",
      lastName: "",
      email: "",
      phone: "",
      company: "",
      experience: 0,
      skills: [{ name: "" }],
      bio: "",
      newsletter: false,
    },
    mode: "onBlur",          // Validate on blur for better UX
    reValidateMode: "onChange", // Re-validate on change after first submit
  });

  const { fields, append, remove } = useFieldArray({ control, name: "skills" });

  const bioLength = watch("bio")?.length ?? 0;

  const onSubmit = async (data: ContactFormData) => {
    // data is fully typed and validated at this point
    console.log("Validated form data:", data);
    try {
      const response = await fetch("/api/contacts", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data),
      });
      if (!response.ok) throw new Error("Failed to submit");
    } catch (error) {
      console.error("Submission error:", error);
      throw error; // Let react-hook-form handle the error state
    }
  };

  if (isSubmitSuccessful) {
    return (
      <div className="success-message" role="status">
        <h2>Thank you!</h2>
        <p>Your information has been submitted successfully.</p>
        <button type="button" onClick={() => reset()}>Submit another</button>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} noValidate>
      <h2>Contact Form</h2>

      {/* Root-level form errors */}
      {errors.root && (
        <div className="form-error" role="alert">{errors.root.message}</div>
      )}

      <div className="form-row">
        <FormField name="firstName" label="First Name" register={register} errors={errors} required />
        <FormField name="lastName" label="Last Name" register={register} errors={errors} required />
      </div>

      <FormField name="email" label="Email" register={register} errors={errors} type="email" required placeholder="you@example.com" />
      <FormField name="phone" label="Phone" register={register} errors={errors} type="tel" placeholder="+1 (555) 000-0000" />
      <FormField name="company" label="Company" register={register} errors={errors} />

      <SelectField
        name="role"
        label="Role"
        register={register}
        errors={errors}
        required
        options={[
          { value: "developer", label: "Developer" },
          { value: "designer", label: "Designer" },
          { value: "manager", label: "Manager" },
          { value: "other", label: "Other" },
        ]}
      />

      <FormField name="experience" label="Years of Experience" register={register} errors={errors} type="number" required />

      {/* Dynamic field array */}
      <fieldset>
        <legend>Skills *</legend>
        {fields.map((field, index) => (
          <div key={field.id} className="skill-row">
            <FormField
              name={`skills.${index}.name` as const}
              label={`Skill ${index + 1}`}
              register={register}
              errors={errors}
            />
            {fields.length > 1 && (
              <button type="button" onClick={() => remove(index)} aria-label={`Remove skill ${index + 1}`}>
                ✕
              </button>
            )}
          </div>
        ))}
        {errors.skills?.message && <p className="error" role="alert">{errors.skills.message}</p>}
        {fields.length < 10 && (
          <button type="button" onClick={() => append({ name: "" })}>+ Add Skill</button>
        )}
      </fieldset>

      {/* Textarea with character count */}
      <div className="form-field">
        <label htmlFor="bio">Bio</label>
        <textarea id="bio" {...register("bio")} maxLength={500} rows={4} />
        <span className="char-count">{bioLength}/500</span>
        {errors.bio && <p className="error" role="alert">{errors.bio.message}</p>}
      </div>

      {/* Checkboxes */}
      <div className="form-field checkbox">
        <label>
          <input type="checkbox" {...register("newsletter")} />
          Subscribe to newsletter
        </label>
      </div>

      <div className="form-field checkbox">
        <label>
          <input type="checkbox" {...register("terms")} />
          I accept the terms and conditions *
        </label>
        {errors.terms && <p className="error" role="alert">{errors.terms.message}</p>}
      </div>

      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? "Submitting..." : "Submit"}
      </button>

      {isDirty && (
        <button type="button" onClick={() => reset()} className="secondary">
          Reset
        </button>
      )}
    </form>
  );
}

export default ContactForm;
