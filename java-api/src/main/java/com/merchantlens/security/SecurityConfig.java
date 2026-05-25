package com.merchantlens.security;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

/**
 * SecurityConfig.java
 *
 * DevSecOps — Spring Security hardening for the MerchantLens API.
 *
 * Key decisions aligned with OWASP API Security Top 10:
 *
 *  API1  — Broken Object Level Authorization:
 *          @PreAuthorize on each endpoint; service layer re-checks merchant ownership.
 *
 *  API2  — Broken Authentication:
 *          Stateless JWT with short expiry (15 min access, 7-day refresh).
 *          No session cookies — CSRF surface eliminated.
 *
 *  API3  — Excessive Data Exposure:
 *          Response DTOs explicitly whitelist fields; no entity objects
 *          returned directly from JPA (prevents accidental field leakage).
 *
 *  API8  — Security Misconfiguration:
 *          HTTPS enforced. HSTS header set. CORS locked to known origins.
 *          Actuator health endpoint exposed but management endpoints require ADMIN.
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity(prePostEnabled = true)
public class SecurityConfig {

    private final JwtAuthenticationFilter jwtAuthFilter;

    public SecurityConfig(JwtAuthenticationFilter jwtAuthFilter) {
        this.jwtAuthFilter = jwtAuthFilter;
    }

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        return http
            // Disable CSRF — API is stateless, no session cookies
            .csrf(csrf -> csrf.disable())

            // CORS — only allow known origins (Salesforce org + internal dashboard)
            .cors(cors -> cors.configurationSource(corsConfigurationSource()))

            // Session management: completely stateless (JWT only)
            .sessionManagement(session ->
                session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))

            // Authorization rules
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/v1/auth/**").permitAll()       // login/refresh
                .requestMatchers("/actuator/health").permitAll()       // load-balancer probe
                .requestMatchers("/actuator/**").hasRole("ADMIN")      // restrict other actuator
                .anyRequest().authenticated()
            )

            // Add JWT filter before username/password filter
            .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class)

            // Security response headers
            .headers(headers -> headers
                .httpStrictTransportSecurity(hsts -> hsts
                    .includeSubDomains(true)
                    .maxAgeInSeconds(31536000))
                .contentSecurityPolicy(csp ->
                    csp.policyDirectives("default-src 'self'"))
                .frameOptions(frame -> frame.deny())
            )

            .build();
    }

    @Bean
    public org.springframework.web.cors.CorsConfigurationSource corsConfigurationSource() {
        org.springframework.web.cors.CorsConfiguration config =
            new org.springframework.web.cors.CorsConfiguration();

        // Only allow requests from our Salesforce org and internal dashboard
        config.setAllowedOrigins(java.util.List.of(
            "https://merchantlens.my.salesforce.com",
            "https://dashboard.merchantlens.internal"
        ));
        config.setAllowedMethods(java.util.List.of("GET", "POST", "PUT", "PATCH"));
        config.setAllowedHeaders(java.util.List.of("Authorization", "Content-Type"));
        config.setAllowCredentials(false);  // No cookies — JWT in header only

        org.springframework.web.cors.UrlBasedCorsConfigurationSource source =
            new org.springframework.web.cors.UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/api/**", config);
        return source;
    }
}
