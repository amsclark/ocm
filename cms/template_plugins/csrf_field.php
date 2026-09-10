<?php
/**
 * csrf_field — renders the hidden CSRF input for a form.
 *
 * Usage in a template, immediately after the opening <form> tag of any
 * form that POSTs:
 *
 *     %%[csrf_field]%%
 *
 * The token comes from pl_csrf_token(), which persists it in the
 * csrf_tokens table; see the CSRF section of cms/app/lib/pl.php for why
 * it cannot live in $_SESSION.
 *
 * A bare tag like the one above resolves through the plain-variable
 * lookup path, and pikaTempLib::draw() and pl_template() both pre-fill
 * $data['csrf_field'] with pl_csrf_hidden_input() so that path finds a
 * value. This plugin covers the explicit %%[field,csrf_field]%% form and
 * any renderer that does not go through either of those.
 */

function csrf_field($field_name = null, $field_value = null, $menu_array = null, $args = null, $data = null)
{
	if (function_exists('pl_csrf_hidden_input')) {
		return pl_csrf_hidden_input();
	}
	return '';
}
