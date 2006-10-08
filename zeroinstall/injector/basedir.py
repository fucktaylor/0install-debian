"""
Support code for the freedesktop.org basedir spec.

This module provides functions for locating configuration files.

@see: U{http://freedesktop.org/wiki/Standards/basedir-spec}
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os

_home = os.environ.get('HOME', '/')

xdg_cache_home = os.environ.get('XDG_CACHE_HOME',
			os.path.join(_home, '.cache'))

xdg_cache_dirs = [xdg_cache_home] + \
	os.environ.get('XDG_CACHE_DIRS', '').split(':')

xdg_config_home = os.environ.get('XDG_CONFIG_HOME',
			os.path.join(_home, '.config'))

xdg_config_dirs = [xdg_config_home] + \
	os.environ.get('XDG_CONFIG_DIRS', '/etc/xdg').split(':')

xdg_cache_dirs = filter(lambda x: x, xdg_cache_dirs)
xdg_config_dirs = filter(lambda x: x, xdg_config_dirs)

def save_config_path(*resource):
	"""Ensure $XDG_CONFIG_HOME/<resource>/ exists, and return its path.
	'resource' should normally be the name of your application. Use this
	when SAVING configuration settings. Use the xdg_config_dirs variable
	for loading."""
	resource = os.path.join(*resource)
	assert not resource.startswith('/')
	path = os.path.join(xdg_config_home, resource)
	if not os.path.isdir(path):
		os.makedirs(path, 0700)
	return path

def load_config_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	configuration search path. Information provided by earlier directories should
	take precedence over later ones (ie, the user's config dir comes first)."""
	resource = os.path.join(*resource)
	for config_dir in xdg_config_dirs:
		path = os.path.join(config_dir, resource)
		if os.path.exists(path): yield path

def load_first_config(*resource):
	"""Returns the first result from load_config_paths, or None if there is nothing
	to load."""
	for x in load_config_paths(*resource):
		return x
	return None


def save_cache_path(*resource):
	"""Ensure $XDG_CACHE_HOME/<resource>/ exists, and return its path.
	'resource' should normally be the name of your application."""
	resource = os.path.join(*resource)
	assert not resource.startswith('/')
	path = os.path.join(xdg_cache_home, resource)
	if not os.path.isdir(path):
		os.makedirs(path, 0700)
	return path

def load_cache_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	cache search path. Information provided by earlier directories should
	take precedence over later ones (ie, the user's cache dir comes first)."""
	resource = os.path.join(*resource)
	for cache_dir in xdg_cache_dirs:
		path = os.path.join(cache_dir, resource)
		if os.path.exists(path): yield path

def load_first_cache(*resource):
	"""Returns the first result from load_cache_paths, or None if there is nothing
	to load."""
	for x in load_cache_paths(*resource):
		return x
	return None
