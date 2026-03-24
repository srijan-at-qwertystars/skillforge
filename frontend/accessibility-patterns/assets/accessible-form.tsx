/**
 * Accessible Form Template
 *
 * Features:
 * - Visible labels associated via htmlFor/id
 * - Error messages linked with aria-describedby
 * - Required field indicators (visual + screen reader)
 * - Fieldset/legend for grouped controls
 * - Live validation announcements via aria-live region
 * - Error summary with links to each invalid field
 * - Proper autocomplete attributes
 *
 * Usage:
 *   <AccessibleForm onSubmit={(data) => console.log(data)} />
 */

import React, { useState, useRef, useEffect, useCallback, useId } from 'react';

// --- Types ---

interface FieldError {
  field: string;
  message: string;
}

interface FormData {
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  password: string;
  confirmPassword: string;
  notifications: string[];
  agreeToTerms: boolean;
}

interface AccessibleFormProps {
  onSubmit: (data: FormData) => void;
}

// --- Reusable Field Component ---

interface FormFieldProps {
  id: string;
  label: string;
  type?: string;
  required?: boolean;
  error?: string;
  hint?: string;
  autoComplete?: string;
  value: string;
  onChange: (value: string) => void;
  onBlur?: () => void;
}

function FormField({
  id,
  label,
  type = 'text',
  required = false,
  error,
  hint,
  autoComplete,
  value,
  onChange,
  onBlur,
}: FormFieldProps) {
  const hintId = `${id}-hint`;
  const errorId = `${id}-error`;

  const describedBy = [
    hint ? hintId : null,
    error ? errorId : null,
  ]
    .filter(Boolean)
    .join(' ') || undefined;

  return (
    <div style={{ marginBottom: '16px' }}>
      <label
        htmlFor={id}
        style={{ display: 'block', marginBottom: '4px', fontWeight: 600 }}
      >
        {label}
        {required && (
          <>
            <span aria-hidden="true" style={{ color: '#d32f2f', marginLeft: '4px' }}>
              *
            </span>
            <span
              style={{
                position: 'absolute',
                width: '1px',
                height: '1px',
                overflow: 'hidden',
                clip: 'rect(0,0,0,0)',
              }}
            >
              {' '}
              (required)
            </span>
          </>
        )}
      </label>
      <input
        id={id}
        type={type}
        required={required}
        aria-required={required}
        aria-invalid={!!error}
        aria-describedby={describedBy}
        autoComplete={autoComplete}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onBlur={onBlur}
        style={{
          display: 'block',
          width: '100%',
          padding: '8px 12px',
          fontSize: '16px',
          border: error ? '2px solid #d32f2f' : '1px solid #ccc',
          borderRadius: '4px',
          boxSizing: 'border-box',
        }}
      />
      {hint && !error && (
        <p
          id={hintId}
          style={{ margin: '4px 0 0', fontSize: '14px', color: '#666' }}
        >
          {hint}
        </p>
      )}
      {error && (
        <p
          id={errorId}
          role="alert"
          style={{ margin: '4px 0 0', fontSize: '14px', color: '#d32f2f' }}
        >
          ⚠ {error}
        </p>
      )}
    </div>
  );
}

// --- Main Form Component ---

export function AccessibleForm({ onSubmit }: AccessibleFormProps) {
  const formId = useId();
  const errorSummaryRef = useRef<HTMLDivElement>(null);
  const announcerRef = useRef<HTMLDivElement>(null);

  const [formData, setFormData] = useState<FormData>({
    firstName: '',
    lastName: '',
    email: '',
    phone: '',
    password: '',
    confirmPassword: '',
    notifications: [],
    agreeToTerms: false,
  });

  const [errors, setErrors] = useState<FieldError[]>([]);
  const [submitted, setSubmitted] = useState(false);

  const updateField = useCallback(
    <K extends keyof FormData>(field: K, value: FormData[K]) => {
      setFormData((prev) => ({ ...prev, [field]: value }));
      // Clear field error on change
      if (submitted) {
        setErrors((prev) => prev.filter((e) => e.field !== field));
      }
    },
    [submitted]
  );

  const announce = useCallback((message: string) => {
    if (announcerRef.current) {
      announcerRef.current.textContent = '';
      requestAnimationFrame(() => {
        if (announcerRef.current) {
          announcerRef.current.textContent = message;
        }
      });
    }
  }, []);

  const validate = (): FieldError[] => {
    const errs: FieldError[] = [];

    if (!formData.firstName.trim()) {
      errs.push({ field: 'firstName', message: 'First name is required' });
    }
    if (!formData.lastName.trim()) {
      errs.push({ field: 'lastName', message: 'Last name is required' });
    }
    if (!formData.email.trim()) {
      errs.push({ field: 'email', message: 'Email address is required' });
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(formData.email)) {
      errs.push({ field: 'email', message: 'Enter a valid email address' });
    }
    if (formData.phone && !/^[\d\s\-+()]+$/.test(formData.phone)) {
      errs.push({ field: 'phone', message: 'Enter a valid phone number' });
    }
    if (!formData.password) {
      errs.push({ field: 'password', message: 'Password is required' });
    } else if (formData.password.length < 8) {
      errs.push({ field: 'password', message: 'Password must be at least 8 characters' });
    }
    if (formData.password !== formData.confirmPassword) {
      errs.push({ field: 'confirmPassword', message: 'Passwords do not match' });
    }
    if (!formData.agreeToTerms) {
      errs.push({ field: 'agreeToTerms', message: 'You must agree to the terms' });
    }

    return errs;
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitted(true);

    const validationErrors = validate();
    setErrors(validationErrors);

    if (validationErrors.length > 0) {
      announce(`Form has ${validationErrors.length} error${validationErrors.length > 1 ? 's' : ''}. Please review.`);
      // Focus error summary after render
      requestAnimationFrame(() => {
        errorSummaryRef.current?.focus();
      });
      return;
    }

    announce('Form submitted successfully.');
    onSubmit(formData);
  };

  const getError = (field: string): string | undefined =>
    errors.find((e) => e.field === field)?.message;

  const handleCheckboxChange = (value: string) => {
    setFormData((prev) => ({
      ...prev,
      notifications: prev.notifications.includes(value)
        ? prev.notifications.filter((v) => v !== value)
        : [...prev.notifications, value],
    }));
  };

  return (
    <form onSubmit={handleSubmit} noValidate aria-label="Registration form">
      {/* Live region for announcements */}
      <div
        ref={announcerRef}
        role="status"
        aria-live="polite"
        aria-atomic="true"
        style={{
          position: 'absolute',
          width: '1px',
          height: '1px',
          overflow: 'hidden',
          clip: 'rect(0,0,0,0)',
        }}
      />

      {/* Error Summary */}
      {errors.length > 0 && (
        <div
          ref={errorSummaryRef}
          role="alert"
          tabIndex={-1}
          style={{
            padding: '16px',
            marginBottom: '24px',
            border: '2px solid #d32f2f',
            borderRadius: '4px',
            backgroundColor: '#fef2f2',
          }}
        >
          <h2 style={{ margin: '0 0 8px', fontSize: '18px', color: '#d32f2f' }}>
            Please fix the following {errors.length} error{errors.length > 1 ? 's' : ''}:
          </h2>
          <ul style={{ margin: 0, paddingLeft: '20px' }}>
            {errors.map((err) => (
              <li key={err.field}>
                <a
                  href={`#${formId}-${err.field}`}
                  style={{ color: '#d32f2f' }}
                  onClick={(e) => {
                    e.preventDefault();
                    document.getElementById(`${formId}-${err.field}`)?.focus();
                  }}
                >
                  {err.message}
                </a>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Name fields */}
      <fieldset style={{ border: 'none', padding: 0, margin: '0 0 24px' }}>
        <legend style={{ fontSize: '18px', fontWeight: 700, marginBottom: '12px' }}>
          Personal Information
        </legend>

        <FormField
          id={`${formId}-firstName`}
          label="First name"
          required
          autoComplete="given-name"
          error={getError('firstName')}
          value={formData.firstName}
          onChange={(v) => updateField('firstName', v)}
        />

        <FormField
          id={`${formId}-lastName`}
          label="Last name"
          required
          autoComplete="family-name"
          error={getError('lastName')}
          value={formData.lastName}
          onChange={(v) => updateField('lastName', v)}
        />

        <FormField
          id={`${formId}-email`}
          label="Email address"
          type="email"
          required
          autoComplete="email"
          hint="We'll never share your email with anyone."
          error={getError('email')}
          value={formData.email}
          onChange={(v) => updateField('email', v)}
        />

        <FormField
          id={`${formId}-phone`}
          label="Phone number"
          type="tel"
          autoComplete="tel"
          hint="Optional. Include country code for international numbers."
          error={getError('phone')}
          value={formData.phone}
          onChange={(v) => updateField('phone', v)}
        />
      </fieldset>

      {/* Password fields */}
      <fieldset style={{ border: 'none', padding: 0, margin: '0 0 24px' }}>
        <legend style={{ fontSize: '18px', fontWeight: 700, marginBottom: '12px' }}>
          Security
        </legend>

        <FormField
          id={`${formId}-password`}
          label="Password"
          type="password"
          required
          autoComplete="new-password"
          hint="Must be at least 8 characters."
          error={getError('password')}
          value={formData.password}
          onChange={(v) => updateField('password', v)}
        />

        <FormField
          id={`${formId}-confirmPassword`}
          label="Confirm password"
          type="password"
          required
          autoComplete="new-password"
          error={getError('confirmPassword')}
          value={formData.confirmPassword}
          onChange={(v) => updateField('confirmPassword', v)}
        />
      </fieldset>

      {/* Notification preferences */}
      <fieldset style={{ border: 'none', padding: 0, margin: '0 0 24px' }}>
        <legend style={{ fontSize: '18px', fontWeight: 700, marginBottom: '12px' }}>
          Notification Preferences
        </legend>
        {['email', 'sms', 'push'].map((type) => (
          <label
            key={type}
            style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '8px' }}
          >
            <input
              type="checkbox"
              name="notifications"
              value={type}
              checked={formData.notifications.includes(type)}
              onChange={() => handleCheckboxChange(type)}
            />
            {type.charAt(0).toUpperCase() + type.slice(1)} notifications
          </label>
        ))}
      </fieldset>

      {/* Terms agreement */}
      <div style={{ marginBottom: '24px' }}>
        <label style={{ display: 'flex', alignItems: 'flex-start', gap: '8px' }}>
          <input
            id={`${formId}-agreeToTerms`}
            type="checkbox"
            checked={formData.agreeToTerms}
            onChange={(e) => updateField('agreeToTerms', e.target.checked)}
            aria-invalid={!!getError('agreeToTerms')}
            aria-describedby={getError('agreeToTerms') ? `${formId}-terms-error` : undefined}
            style={{ marginTop: '4px' }}
          />
          <span>
            I agree to the{' '}
            <a href="/terms" target="_blank" rel="noopener noreferrer">
              Terms of Service
              <span
                style={{
                  position: 'absolute',
                  width: '1px',
                  height: '1px',
                  overflow: 'hidden',
                  clip: 'rect(0,0,0,0)',
                }}
              >
                {' '}
                (opens in a new tab)
              </span>
            </a>{' '}
            <span aria-hidden="true" style={{ color: '#d32f2f' }}>
              *
            </span>
          </span>
        </label>
        {getError('agreeToTerms') && (
          <p
            id={`${formId}-terms-error`}
            role="alert"
            style={{ margin: '4px 0 0 28px', fontSize: '14px', color: '#d32f2f' }}
          >
            ⚠ {getError('agreeToTerms')}
          </p>
        )}
      </div>

      <button
        type="submit"
        style={{
          padding: '12px 24px',
          fontSize: '16px',
          fontWeight: 600,
          backgroundColor: '#1976d2',
          color: 'white',
          border: 'none',
          borderRadius: '4px',
          cursor: 'pointer',
          minHeight: '44px',
          minWidth: '44px',
        }}
      >
        Create Account
      </button>
    </form>
  );
}

export default AccessibleForm;
