//! WebAssembly Component Implementation Template
//!
//! This file implements a WIT world. The `bindings` module is auto-generated
//! by cargo-component from your WIT files in the `wit/` directory.
//!
//! Build: cargo component build --release
//! Test:  cargo test

#[allow(warnings)]
mod bindings;

use bindings::exports::example::hello_world::greetings::{self, Guest, Greeting};

struct Component;

impl Guest for Component {
    /// Generate a greeting for the given name
    fn greet(name: String) -> Greeting {
        Greeting {
            message: format!("Hello, {name}!"),
            timestamp: current_timestamp(),
        }
    }

    /// Generate a greeting with a custom template
    fn greet_custom(name: String, template: String) -> Result<Greeting, String> {
        if !template.contains("{name}") {
            return Err("template must contain \"{name}\" placeholder".to_string());
        }

        let message = template.replace("{name}", &name);
        Ok(Greeting {
            message,
            timestamp: current_timestamp(),
        })
    }
}

/// Get a monotonic timestamp (milliseconds).
/// In a real component, use wasi:clocks/monotonic-clock.
fn current_timestamp() -> u64 {
    0 // placeholder — replace with actual clock import
}

// Export the component implementation, binding it to the generated types
bindings::export!(Component with_types_in bindings);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greet() {
        let result = Component::greet("World".to_string());
        assert_eq!(result.message, "Hello, World!");
    }

    #[test]
    fn test_greet_custom_ok() {
        let result = Component::greet_custom(
            "Alice".to_string(),
            "Welcome, {name}! Glad to see you.".to_string(),
        );
        assert!(result.is_ok());
        assert_eq!(result.unwrap().message, "Welcome, Alice! Glad to see you.");
    }

    #[test]
    fn test_greet_custom_missing_placeholder() {
        let result = Component::greet_custom(
            "Alice".to_string(),
            "No placeholder here".to_string(),
        );
        assert!(result.is_err());
    }
}
