<?php

if ( ! defined( 'ABSPATH' ) ) {
	exit( 1 );
}

echo "Configuring common plugins...\n";

/*
 * Yoast SEO
 *
 * Configure Northstar Digital as an organization and provide sensible
 * homepage/site metadata. Preserve any other Yoast values already present.
 */
if ( defined( 'WPSEO_VERSION' ) || class_exists( 'WPSEO_Options' ) ) {
	$titles = get_option( 'wpseo_titles', array() );

	if ( ! is_array( $titles ) ) {
		$titles = array();
	}

	$titles['website_name'] = 'Northstar Digital';
	$titles['alternate_website_name'] = 'Northstar';
	$titles['company_or_person'] = 'company';
	$titles['company_name'] = 'Northstar Digital';
	$titles['company_alternate_name'] = 'Northstar';
	$titles['title-home-wpseo'] = 'Northstar Digital %%sep%% Cloud, DevOps & Security Engineering';
	$titles['metadesc-home-wpseo'] = 'Northstar Digital is a fictional cloud, DevOps, platform engineering and security consultancy used by this Kubernetes WordPress PoC.';
	$titles['open_graph_frontpage_title'] = 'Northstar Digital';
	$titles['open_graph_frontpage_desc'] = 'Cloud, DevOps, platform engineering and security engineering for growing teams.';
	$titles['breadcrumbs-enable'] = true;

	update_option( 'wpseo_titles', $titles );

	$seo_meta = array(
		'home' => array(
			'title' => 'Cloud, DevOps & Security Engineering | Northstar Digital',
			'description' => 'Northstar Digital helps teams build reliable cloud platforms, automate delivery and integrate security into engineering workflows.',
		),
		'services' => array(
			'title' => 'Cloud, DevOps & Security Services | Northstar Digital',
			'description' => 'Cloud engineering, Kubernetes, CI/CD, DevSecOps, platform engineering, observability and reliability services.',
		),
		'case-studies' => array(
			'title' => 'Cloud & Platform Engineering Case Studies | Northstar Digital',
			'description' => 'Fictional examples of Kubernetes migrations, secure CI/CD platforms and highly available cloud architectures.',
		),
		'contact' => array(
			'title' => 'Contact Northstar Digital',
			'description' => 'Get in touch with the fictional Northstar Digital cloud, DevOps and security engineering team.',
		),
	);

	foreach ( $seo_meta as $slug => $values ) {
		$page = get_page_by_path( $slug, OBJECT, 'page' );

		if ( $page ) {
			update_post_meta( $page->ID, '_yoast_wpseo_title', $values['title'] );
			update_post_meta( $page->ID, '_yoast_wpseo_metadesc', $values['description'] );
		}
	}

	echo "  Yoast SEO: organization and page metadata configured.\n";
}

/*
 * Contact Form 7 + Flamingo
 *
 * Build one deterministic form. Mail is deliberately skipped in this local
 * PoC, but Flamingo still stores submissions in the WordPress database.
 */
$contact_content = null;

if ( class_exists( 'WPCF7_ContactForm' ) ) {
	$form = null;

	$form_posts = get_posts(
		array(
			'post_type'      => 'wpcf7_contact_form',
			'post_status'    => 'any',
			'posts_per_page' => -1,
		)
	);

	foreach ( $form_posts as $form_post ) {
		if ( $form_post->post_title === 'Northstar Project Enquiry' ) {
			$form = WPCF7_ContactForm::get_instance( $form_post->ID );
			break;
		}
	}

	if ( ! $form ) {
		$form = WPCF7_ContactForm::get_template(
			array(
				'title' => 'Northstar Project Enquiry',
			)
		);
	}

	$form_markup = <<<'FORM'
<label>Your name
[text* your-name autocomplete:name placeholder "Jane Smith"]</label>

<label>Work email
[email* your-email autocomplete:email placeholder "jane@example.com"]</label>

<label>Company
[text your-company autocomplete:organization placeholder "Example Company"]</label>

<label>What can we help with?
[select* your-subject "Cloud migration" "Kubernetes platform" "CI/CD and DevSecOps" "Reliability and observability" "Security assessment" "Other"]</label>

<label>Project details
[textarea* your-message 8x40 placeholder "Tell us a little about the project, current environment and goals."]</label>

[acceptance privacy-consent] I understand this is a fictional local PoC and I will not enter real confidential information. [/acceptance]

[submit "Send project enquiry"]
FORM;

	$additional_settings = implode(
		"\n",
		array(
			'skip_mail: on',
			'flamingo_email: "[your-email]"',
			'flamingo_name: "[your-name]"',
			'flamingo_subject: "[your-subject]"',
		)
	);

	$form->set_properties(
		array(
			'form'                => $form_markup,
			'additional_settings' => $additional_settings,
		)
	);

	$form->save();

	$shortcode = html_entity_decode( $form->shortcode(), ENT_QUOTES );

	$contact_content = <<<CONTENT
<!-- wp:heading {"level":1} --><h1 class="wp-block-heading">Contact</h1><!-- /wp:heading -->
<!-- wp:paragraph --><p>Tell us what you're building or what you want to improve. This is a fictional company used for a local WordPress Kubernetes proof of concept, so please use test data only.</p><!-- /wp:paragraph -->
<!-- wp:columns --><div class="wp-block-columns">
<!-- wp:column --><div class="wp-block-column"><!-- wp:heading {"level":3} --><h3 class="wp-block-heading">Project enquiries</h3><!-- /wp:heading --><!-- wp:paragraph --><p>Email: hello@example.test<br>Phone: +32 2 555 01 23<br>Office: Brussels, Belgium</p><!-- /wp:paragraph --></div><!-- /wp:column -->
<!-- wp:column --><div class="wp-block-column"><!-- wp:heading {"level":3} --><h3 class="wp-block-heading">Typical projects</h3><!-- /wp:heading --><!-- wp:list --><ul class="wp-block-list"><li>Cloud migrations</li><li>Kubernetes platforms</li><li>CI/CD modernization</li><li>DevSecOps assessments</li><li>Reliability improvements</li></ul><!-- /wp:list --></div><!-- /wp:column -->
</div><!-- /wp:columns -->
<!-- wp:separator --><hr class="wp-block-separator has-alpha-channel-opacity"/><!-- /wp:separator -->
<!-- wp:heading {"level":2} --><h2 class="wp-block-heading">Start a conversation</h2><!-- /wp:heading -->
<!-- wp:shortcode -->
{$shortcode}
<!-- /wp:shortcode -->
CONTENT;

	echo "  Contact Form 7: Northstar Project Enquiry configured.\n";

	if ( class_exists( 'Flamingo_Inbound_Message' ) ) {
		echo "  Flamingo: submissions will be stored locally; email delivery is skipped.\n";
	}
}

/*
 * Contact page
 *
 * seed-site.sh only creates the page; its content is owned here. Use the
 * enquiry form when Contact Form 7 is active, otherwise restore the plain
 * contact.html so a removed plugin doesn't leave a dead shortcode behind.
 */
$contact_page = get_page_by_path( 'contact', OBJECT, 'page' );

if ( $contact_page ) {
	if ( null === $contact_content ) {
		$contact_content = trim( (string) file_get_contents( '/bootstrap/contact.html' ) );
	}

	// Compare with what WordPress would store. content_save_pre applies kses
	// filtering when the current user lacks unfiltered_html (always true under
	// WP-CLI), so comparing the raw source would always differ. The filter
	// expects slashed data, as wp_update_post() receives it below, so slash the
	// source and unslash the result; otherwise a backslash in the content
	// would make the page differ on every run.
	$stored_content = wp_unslash( apply_filters( 'content_save_pre', wp_slash( $contact_content ) ) );

	// Leave an unchanged page alone so repeated runs don't touch it.
	if ( $contact_page->post_content !== $stored_content ) {
		wp_update_post(
			array(
				'ID'           => $contact_page->ID,
				'post_content' => wp_slash( $contact_content ),
			)
		);
	}
}

/*
 * Query Monitor
 *
 * Its useful defaults require no persistent settings for this development PoC.
 */
if ( defined( 'QM_VERSION' ) || class_exists( 'QueryMonitor' ) ) {
	echo "  Query Monitor: active with development defaults.\n";
}

echo "Common plugin configuration complete.\n";
