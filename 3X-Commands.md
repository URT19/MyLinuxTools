```
sudo apt install -y sqlite3
```

#### لیست اینباندها
```
sudo sqlite3 /etc/x-ui/x-ui.db "SELECT id, remark, protocol, port FROM inbounds;"
```
----
### استخراج مسیر path از طریق id inbound

```
sudo sqlite3 /etc/x-ui/x-ui.db "SELECT json_extract(stream_settings,'$.wsSettings.path') FROM inbounds WHERE id=22;"
```

----

