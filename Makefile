.DEFAULT_GOAL := help

start: ## Run Server
	@sudo systemctl start isu-ruby

stop: ## Stop Server
	@sudo systemctl stop isu-ruby

log: ## log Server
	@sudo journalctl -u isu-ruby

config: ## copy configs from repository to conf
	@sudo cp ~/private_isu/webapp/conf/systemd/isu-ruby.service /etc/systemd/system/
	@sudo cp ~/private_isu/webapp/conf/nginx/nginx.conf /etc/nginx/
	@sudo cp ~/private_isu/webapp/conf/nginx/isucon.conf /etc/nginx/conf.d/
	@sudo cp ~/private_isu/webapp/conf/mysql/my.cnf /etc/mysql/
	@make -s restart
	@make -s nginx-restart
	@make -s db-restart

restart: ## Restart Server
	@sudo systemctl daemon-reload
	@cd webapp/ruby; bundle 1> /dev/null
	@sudo systemctl restart isu-ruby
	@echo 'Restart isu-ruby'

db-restart: ## Restart mysql
	@sudo service mysql restart
	@echo 'Restart mysql'

nginx-restart: ## Restart nginx
	@sudo service nginx restart
	@echo 'Restart nginx'

nginx-reset-log: ## reest log and restart nginx
	@sudo rm /var/log/nginx/access.log;sudo service nginx restart

nginx-log: ## tail nginx access.log
	@sudo tail -f /var/log/nginx/access.log

nginx-error-log: ## tail nginx error.log
	@sudo tail -f /var/log/nginx/error.log

myprofiler: ## Run myprofiler
	@myprofiler -user=root

db-slow-query: ## tail slow query log
	@sudo tail -f /var/log/mysql/mysql-slow.log

alp: ## nginx analyzer
	@sudo /home/isucon/gocode/bin/alp -f /var/log/nginx/access.log ${ARGS}

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
