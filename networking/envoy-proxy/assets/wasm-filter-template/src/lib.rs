use log::info;
use proxy_wasm::traits::*;
use proxy_wasm::types::*;
use serde::Deserialize;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> {
        Box::new(FilterRoot {
            config: FilterConfig::default(),
        })
    });
}}

// ── Configuration ──────────────────────────────────────────

#[derive(Deserialize, Debug, Clone)]
struct FilterConfig {
    /// Header name to add to requests
    #[serde(default = "default_header_name")]
    header_name: String,

    /// Header value to set
    #[serde(default = "default_header_value")]
    header_value: String,
}

impl Default for FilterConfig {
    fn default() -> Self {
        Self {
            header_name: default_header_name(),
            header_value: default_header_value(),
        }
    }
}

fn default_header_name() -> String {
    "x-wasm-filter".to_string()
}

fn default_header_value() -> String {
    "active".to_string()
}

// ── Root Context (VM lifecycle) ────────────────────────────

struct FilterRoot {
    config: FilterConfig,
}

impl Context for FilterRoot {}

impl RootContext for FilterRoot {
    fn on_configure(&mut self, _plugin_configuration_size: usize) -> bool {
        match self.get_plugin_configuration() {
            Some(config_bytes) => {
                match serde_json::from_slice::<FilterConfig>(&config_bytes) {
                    Ok(config) => {
                        info!("Filter configured: {:?}", config);
                        self.config = config;
                        true
                    }
                    Err(e) => {
                        log::error!("Failed to parse config: {}", e);
                        false
                    }
                }
            }
            None => {
                info!("No config provided, using defaults");
                true
            }
        }
    }

    fn create_http_context(&self, context_id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(FilterContext {
            context_id,
            config: self.config.clone(),
        }))
    }

    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
}

// ── HTTP Context (per-request) ─────────────────────────────

struct FilterContext {
    context_id: u32,
    config: FilterConfig,
}

impl Context for FilterContext {}

impl HttpContext for FilterContext {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        // Add configured header
        self.add_http_request_header(&self.config.header_name, &self.config.header_value);

        // Log the request
        if let Some(path) = self.get_http_request_header(":path") {
            let method = self.get_http_request_header(":method").unwrap_or_default();
            info!(
                "[ctx={}] {} {} — added header {}={}",
                self.context_id, method, path, self.config.header_name, self.config.header_value
            );
        }

        Action::Continue
    }

    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        self.add_http_response_header("x-wasm-processed", "true");
        Action::Continue
    }

    fn on_log(&mut self) {
        // Called when the stream is complete — useful for access logging
        if let Some(status) = self.get_http_response_header(":status") {
            info!("[ctx={}] completed with status {}", self.context_id, status);
        }
    }
}
