A plugin to fix elementor css generation on Shifter.

# Why Elementor is broken on Shifter's static side
When using Shifter with the optional "Media CDN", the entire contents of your Wordpress `/uploads` folder are redirected to an S3 bucket. This is not configurable, and the plugin that accomplishes this is hidden.

Elementor, and other plugins, puts generated CSS files in the `/uploads` folder. The CDN is shared across the staging site and all artifacts, so deleting an item in one place deletes it from all -- including, as Shifter warns, deleting an image in your Wordpress backend deletes it from your live site.

This is not much of a problem for media items, you just need to make sure you only either intentionally overwrite a file by name universally, or save it to a new name. Using unique names for uploads will guarantee that your new deploy uses your latest CDN stuff.

Elementor, however, does not use unique names for CSS files, but instead uses the `?ver=` cache-busting trick that is meant for dynamic Wordpress sites. Despite Shifter's claim of Elementor support, this means that the cache-busting trick does not work, and Elementor just overwrites the same CSS file on the CDN, potentially affecting your live site.

Well, it would affect your live site, except that the CDN has its own cache that can't be configured, which is set to a 1 YEAR EXPIRATION. This means that anyone who visits your site via a CDN node that has seen the file before (e.g. you) will give you the same CSS file as up to a year ago (!), no matter how many times you've updated since then.

This creates the frustrating experience where you make meticulous edits in Elementor, it looks good on the live Wordpress ("staging") site's frontend preview, you build an artifact and deploy and... the changes aren't there.

# Internal Embedding - not a solution

The suggested workaround is usually to use Elementor's "Internal Embedding" mode for writing CSS, which inlines all CSS into *every* page. Not only is this woefully inefficent, but Elementor's settings page even says this is for debugging, and in practice, the Internal Embedding mode has way more bugs than the External stylesheet mode, which go overlooked because the dev team doesn't really test it when implementing new features.

Most of these are gnarly CSS specificity bugs that you can't fix without editing Elementor -- the styles are usually all there, but in the wrong order, with weird interactions, and in my experience base template styles end up taking precedence over a page's specific styles, for example. Good luck tracking those down, if you do manage to realize that Internal Embedding is the culprit.

By using External File stylesheets, one artifact for example was 12.4% smaller, with 1895 files instead of 1911. (And that's not even including any of the site-specific stylesheets -- those are hosted on the CDN and excluded from artifact downloads.)

# Unique filenames - almost works

The fix I've been using is a small snippet that renames the files upon creation to use that same `?ver=` string in the filename, and updating all links accordingly. This works!

However, it turns out that the Shifter generator starts fresh and generates every single page in parallel, so it ends up generating the same shared stylesheets hundreds of times with different names.

Worse, Elementor's CSS generation process happens in a few phases, with placeholders in the first pass that get filled in with subsequent passes. If the generator were to get overloaded and time out, the resulting filesheets are left with these placeholders, leading to a worse result than using an outdated copy, and a ton of hard to track down bugs.

In my experience, when the site gets relatively large, these factors combine to a point where

- Artifact generation takes *forever*. I'm talking 15, sometimes 20 minutes, for a few hundred mostly-identical pages. This is about the same as with Internal Embedding, however.
- Some pages are broken. The styles just don't load, and you have to regenerate to get it to come back. Using Elementor's "Regenerate Styles" button doesn't help, because they're generated from scratch anyway during the build process, since it doesn't see anything in the local /uploads/ folder.
- When you regenerate that same site, the broken page may be fixed. But what you may (not immediately) find, is... other pages broke! It is a non-deterministic problem where you play whack-a-mole with broken pages until you think you've finally got a good artifact. When there are hundreds of pages, and only one or two are broken, it's easy to be wrong about that. The code of the broken page is almost exactly the same as the one with the correct stylesheet linked.

# Using a Snippet - Forbidden

While the Wordpress Code Snippets plugin is a godsend, Shifter's hosting service is set up with a very strict WAF filter. In practice, this means that most of the time, you can save your Snippet just fine, but then suddenly, even after a trivial change, you get a 403 Forbidden error when trying to save it on your own site.

Eventually I discovered that certain PHP functions, presumably considered dangerous, are sniffed by the cloud service and cause it to unilaterally reject any request containing them. You have to guess, or do a bisection of your code to figure out which is the problematic term being used.

If we were direct customers of AWS, we could configure this, and hypothetically Shifter should be able to make exceptions upon request. But Shifter's support hasn't been responsive, at least for English-speaking customers, since 2024, so I didn't bother trying that. I was able to get around the WAF by obfuscating the code... so I guess it's not exactly going to prevent the kind of code injection attacks its designed for.

Still, it made sense to just make this a Wordpress plugin, even though it's just one small Snippet. The plugin can be installed with e.g. WP Pusher; uploaded files aren't scanned by WAF the same way.

Hopefully Elementor or Shifter can learn from this plugin and some day this won't be necessary. Until then, hope this helps someone.

# Good: Versioned names (no more stale styles)

I started by intercepting Elementor's stylesheet save and using its `?ver=` version string in the filename instead, e.g. `post-311.1711512345.css`. This means that an old version can be cached and it doesn't matter, we'll get the latest.

Not only that, but now you can preview older artifacts and they'll still have the styles that they did at the time!

# Better: File locks - Artifacts generate 15x faster!

Because Shifter generates pages in parallel, multiple PHP processes may try to create/copy the same CSS file at the exact same millisecond. If that takes too long, whoever gets cutoff at the timeout gets a partial stylesheet... even if theres's hundreds of good copies of the exact same sheet available that met the deadline.

By blocking Shifter from doing this using locks, I finally saw my build times, which had been often exceeding 15 minutes, drop to under a minute... just like it used to be when the site was new!

# Best: Content hash as the version string.

Since Elementor uses dumb timestamps for versions, and the generator runs in parallel, you still get a bunch of copies of the same shared stylesheets with unique names. So, for the sake of CDN space/bandwidth (though not really an issue for CSS) and for the end user's browser cache, the final solution is to keep the locks, but swap the versioning scheme with content hashes. 

# Solution

This plugin automatically calculates an MD5 hash of the stylesheet content, ensuring that even across hundreds of parallel requests, only a single uniquely-named file is produced per CSS state.
