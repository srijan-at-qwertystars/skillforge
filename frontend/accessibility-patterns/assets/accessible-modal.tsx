/**
 * Accessible Modal Dialog Component
 *
 * Features:
 * - Focus trap: Tab/Shift+Tab cycles within modal
 * - Escape to close
 * - aria-modal="true" with proper role="dialog"
 * - Returns focus to trigger element on close
 * - Inert background (prevents interaction outside modal)
 * - Click outside (backdrop) to close
 * - Accessible title via aria-labelledby
 * - Optional description via aria-describedby
 *
 * Usage:
 *   <AccessibleModal
 *     isOpen={showModal}
 *     onClose={() => setShowModal(false)}
 *     title="Confirm Delete"
 *     description="This action cannot be undone."
 *   >
 *     <p>Are you sure you want to delete this item?</p>
 *     <button onClick={handleDelete}>Delete</button>
 *     <button onClick={() => setShowModal(false)}>Cancel</button>
 *   </AccessibleModal>
 */

import React, { useEffect, useRef, useCallback, useId } from 'react';

interface AccessibleModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  description?: string;
  children: React.ReactNode;
  /** Element to receive focus when modal opens. Defaults to first focusable element. */
  initialFocusRef?: React.RefObject<HTMLElement>;
  /** Whether clicking the backdrop closes the modal. Default: true */
  closeOnBackdropClick?: boolean;
  /** Whether pressing Escape closes the modal. Default: true */
  closeOnEscape?: boolean;
  /** Additional CSS class for the dialog element */
  className?: string;
}

const FOCUSABLE_SELECTOR = [
  'a[href]:not([disabled]):not([tabindex="-1"])',
  'button:not([disabled]):not([tabindex="-1"])',
  'input:not([disabled]):not([tabindex="-1"])',
  'select:not([disabled]):not([tabindex="-1"])',
  'textarea:not([disabled]):not([tabindex="-1"])',
  '[tabindex]:not([tabindex="-1"]):not([disabled])',
].join(',');

export function AccessibleModal({
  isOpen,
  onClose,
  title,
  description,
  children,
  initialFocusRef,
  closeOnBackdropClick = true,
  closeOnEscape = true,
  className,
}: AccessibleModalProps) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);
  const titleId = useId();
  const descId = useId();

  // Save and restore focus
  useEffect(() => {
    if (isOpen) {
      previousFocusRef.current = document.activeElement as HTMLElement;

      // Focus initial element or first focusable element in dialog
      requestAnimationFrame(() => {
        if (initialFocusRef?.current) {
          initialFocusRef.current.focus();
        } else if (dialogRef.current) {
          const firstFocusable = dialogRef.current.querySelector<HTMLElement>(FOCUSABLE_SELECTOR);
          if (firstFocusable) {
            firstFocusable.focus();
          } else {
            dialogRef.current.focus();
          }
        }
      });

      // Set inert on all siblings of modal root
      const siblings = document.querySelectorAll('body > *:not([data-modal-overlay])');
      siblings.forEach(el => {
        if (el instanceof HTMLElement) {
          el.setAttribute('inert', '');
          el.setAttribute('aria-hidden', 'true');
        }
      });

      return () => {
        // Remove inert from siblings
        siblings.forEach(el => {
          if (el instanceof HTMLElement) {
            el.removeAttribute('inert');
            el.removeAttribute('aria-hidden');
          }
        });
        // Restore focus
        previousFocusRef.current?.focus();
      };
    }
  }, [isOpen, initialFocusRef]);

  // Focus trap
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Escape' && closeOnEscape) {
        e.stopPropagation();
        onClose();
        return;
      }

      if (e.key === 'Tab' && dialogRef.current) {
        const focusable = Array.from(
          dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)
        );
        if (focusable.length === 0) return;

        const first = focusable[0];
        const last = focusable[focusable.length - 1];

        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    },
    [onClose, closeOnEscape]
  );

  // Backdrop click
  const handleBackdropClick = useCallback(
    (e: React.MouseEvent) => {
      if (closeOnBackdropClick && e.target === e.currentTarget) {
        onClose();
      }
    },
    [onClose, closeOnBackdropClick]
  );

  // Prevent body scroll when modal is open
  useEffect(() => {
    if (isOpen) {
      const originalOverflow = document.body.style.overflow;
      document.body.style.overflow = 'hidden';
      return () => {
        document.body.style.overflow = originalOverflow;
      };
    }
  }, [isOpen]);

  if (!isOpen) return null;

  return (
    <div
      data-modal-overlay
      style={{
        position: 'fixed',
        inset: 0,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(0, 0, 0, 0.5)',
        zIndex: 9999,
      }}
      onClick={handleBackdropClick}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={description ? descId : undefined}
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        className={className}
        style={{
          backgroundColor: 'white',
          borderRadius: '8px',
          padding: '24px',
          maxWidth: '500px',
          width: '90vw',
          maxHeight: '85vh',
          overflowY: 'auto',
          position: 'relative',
          boxShadow: '0 20px 60px rgba(0, 0, 0, 0.3)',
        }}
      >
        <h2 id={titleId} style={{ marginTop: 0 }}>
          {title}
        </h2>
        {description && (
          <p id={descId} style={{ color: '#666' }}>
            {description}
          </p>
        )}
        {children}
        <button
          onClick={onClose}
          aria-label="Close dialog"
          style={{
            position: 'absolute',
            top: '12px',
            right: '12px',
            background: 'none',
            border: 'none',
            fontSize: '24px',
            cursor: 'pointer',
            padding: '4px 8px',
            lineHeight: 1,
          }}
        >
          ×
        </button>
      </div>
    </div>
  );
}

export default AccessibleModal;
